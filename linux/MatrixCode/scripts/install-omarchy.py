#!/usr/bin/env python3
"""Configure the supported Omarchy Quattro idle-plugin clone, without root access."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import sys
import tempfile

LAUNCHER_NAME = "matrixcode-omarchy-screensaver"
STOCK_LAUNCHER = "omarchy-launch-screensaver"
IDLE_PLUGIN = "omarchy.idle"
COMMAND = re.compile(r'runProcess\(screensaverProcess,\s*"screensaver",\s*("(?:[^"\\]|\\.)*")\)')


def fail(message):
    raise RuntimeError(message)


def run(*arguments):
    result = subprocess.run(arguments, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        fail(f"{' '.join(arguments)} failed: {result.stderr.strip() or result.stdout.strip()}")
    return result.stdout.strip()


def read_json(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError) as error:
        fail(f"cannot read {path}: {error}")


def atomic_write(path, content, mode=0o600):
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(content)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def tree_hash(directory):
    digest = hashlib.sha256()
    for path in sorted(directory.rglob("*")):
        if path.is_symlink():
            fail(f"plugin contains a symlink: {path}")
        if path.is_file():
            digest.update(str(path.relative_to(directory)).encode())
            digest.update(b"\0")
            digest.update(path.read_bytes())
    return digest.hexdigest()


def screensaver_command(content):
    matches = list(COMMAND.finditer(content))
    if len(matches) != 1:
        fail("idle Service.qml does not have the supported Quattro screensaver command")
    match = matches[0]
    return match, json.loads(match.group(1))


def patch_command(content, expected, replacement):
    match, command = screensaver_command(content)
    if command.count(expected) != 1:
        fail("idle screensaver command was customized; no files changed")
    updated = command.replace(expected, replacement, 1)
    return content[:match.start(1)] + json.dumps(updated) + content[match.end(1):]


def ensure_safe_session():
    if os.getuid() == 0:
        fail("run this command as your desktop user, without sudo")
    for tool in ("omarchy", "omarchy-shell", "omarchy-restart-shell"):
        if not shutil.which(tool):
            fail(f"required Quattro command is missing: {tool}")
    try:
        lock = json.loads(run("omarchy-shell", "lock", "status"))
        idle = json.loads(run("omarchy-shell", "idle", "status"))
    except ValueError:
        fail("Omarchy shell did not return a valid lock/idle status")
    if not isinstance(lock, dict) or not isinstance(idle, dict):
        fail("Omarchy shell did not return an object for lock/idle status")
    if lock.get("secure") is not False or lock.get("requested") is not False:
        fail("unlock the desktop before changing its idle integration")
    if idle.get("inIdleCycle") is not False:
        fail("dismiss the screensaver before changing its idle integration")


def service_path(plugin_dir):
    manifest = read_json(plugin_dir / "manifest.json")
    if manifest.get("omarchy", {}).get("clonedFrom") != IDLE_PLUGIN:
        fail("the selected plugin is not an Omarchy idle clone")
    relative = Path(manifest.get("entryPoints", {}).get("service", ""))
    if not str(relative) or relative.is_absolute() or ".." in relative.parts:
        fail("the idle clone has an invalid service entry point")
    path = plugin_dir / relative
    if not path.is_file() or path.is_symlink():
        fail("the idle service entry point is missing or a symlink")
    return path


def integration_service(state, plugins_dir):
    plugin_id = state.get("plugin_id", "")
    if not isinstance(plugin_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*", plugin_id) or ".." in plugin_id:
        fail("saved integration has an invalid plugin ID")
    path = service_path(plugins_dir / plugin_id)
    if str(path.relative_to(plugins_dir / plugin_id)) != state.get("service"):
        fail("idle service entry point changed after installation")
    return path


def finish_restart(state, state_path):
    run("omarchy-restart-shell")
    state["restart_pending"] = False
    atomic_write(state_path, json.dumps(state, indent=2) + "\n")


def active_clone(plugins_dir):
    entries = json.loads(run("omarchy", "plugin", "list", "--json"))
    enabled = {entry["id"] for entry in entries if entry.get("enabled") is True}
    clones = []
    for manifest_path in plugins_dir.glob("*/manifest.json"):
        if manifest_path.parent.name.startswith("."):
            continue
        manifest = read_json(manifest_path)
        if manifest.get("omarchy", {}).get("clonedFrom") == IDLE_PLUGIN and manifest.get("id") in enabled:
            clones.append(manifest_path.parent)
    if len(clones) > 1:
        fail("multiple idle clones are enabled; resolve them before installing")
    if clones:
        return clones[0]
    if IDLE_PLUGIN not in enabled:
        fail("the built-in idle service is disabled; enable it before installing")
    return None


def install(args, state_path, plugins_dir):
    if state_path.exists():
        state = read_json(state_path)
        service = integration_service(state, plugins_dir)
        original = service.read_text()
        if state["launcher_command"] not in screensaver_command(original)[1]:
            if not state.get("restart_pending"):
                fail("saved integration differs from the idle plugin; uninstall or inspect it first")
            ensure_safe_session()
            updated = patch_command(original, STOCK_LAUNCHER, state["launcher_command"])
            atomic_write(service, updated, service.stat().st_mode & 0o777)
        if state.get("restart_pending"):
            ensure_safe_session()
            finish_restart(state, state_path)
        print("MatrixCode Omarchy integration is already installed.")
        return
    ensure_safe_session()
    omarchy_path = Path(os.environ.get("OMARCHY_PATH", "/usr/share/omarchy"))
    version_path = omarchy_path / "version"
    if not version_path.is_file() or not version_path.read_text().strip().startswith("4."):
        fail("this integration requires Omarchy 4 (Quattro)")
    launcher = Path(args.launcher or shutil.which(LAUNCHER_NAME) or "").resolve()
    if launcher.name != LAUNCHER_NAME or not os.access(launcher, os.X_OK) or not os.access(launcher.parent / "MatrixCode", os.X_OK):
        fail(f"install {LAUNCHER_NAME} and MatrixCode together before configuring Omarchy")
    plugin_dir = active_clone(plugins_dir)
    created = plugin_dir is None
    if created:
        # Validate the stock interface before the official clone command changes anything.
        stock = omarchy_path / "shell/plugins/services/idle/Service.qml"
        patch_command(stock.read_text(), STOCK_LAUNCHER, shlex.quote(str(launcher)))
        expected_id = f"{os.environ.get('USER') or run('id', '-un')}.idle"
        if (plugins_dir / expected_id).exists():
            fail("an inactive user idle clone already exists; enable it before installing")
        try:
            run("omarchy", "plugin", "clone", IDLE_PLUGIN)
        except RuntimeError:
            # A notification/IPC failure can occur after the clone was enabled.
            target = plugins_dir / expected_id
            if target.exists():
                service_path(target)
                run("omarchy", "plugin", "remove", expected_id, "--yes")
            else:
                run("omarchy-shell", "shell", "rescanPlugins")
            raise
        plugin_dir = active_clone(plugins_dir)
        if plugin_dir is None:
            fail("Omarchy did not enable the cloned idle service")
    service = service_path(plugin_dir)
    original = service.read_text()
    launcher_command = shlex.quote(str(launcher))
    updated = patch_command(original, STOCK_LAUNCHER, launcher_command)
    state = {
        "version": 1,
        "plugin_id": plugin_dir.name,
        "service": str(service.relative_to(plugin_dir)),
        "created_clone": created,
        "launcher_command": launcher_command,
        "original_tree_hash": tree_hash(plugin_dir),
        "restart_pending": True,
    }
    # Record recovery information before changing the live service.
    try:
        atomic_write(state_path.parent / "Service.qml.backup", original)
        atomic_write(state_path, json.dumps(state, indent=2) + "\n")
    except OSError:
        if created:
            run("omarchy", "plugin", "remove", plugin_dir.name, "--yes")
        raise
    atomic_write(service, updated, service.stat().st_mode & 0o777)
    # keepLoaded services may retain the old object after a file edit.
    finish_restart(state, state_path)
    print(f"MatrixCode now uses {plugin_dir.name}; Omarchy retains its screensaver and lock timing.")


def uninstall(state_path, plugins_dir):
    if not state_path.exists():
        print("MatrixCode Omarchy integration is not installed.")
        return
    ensure_safe_session()
    state = read_json(state_path)
    plugin_dir = plugins_dir / state["plugin_id"]
    if not plugin_dir.exists():
        run("omarchy-restart-shell")
        state_path.unlink()
        print("Idle clone was already removed; cleared MatrixCode integration state.")
        return
    service = integration_service(state, plugins_dir)
    original = service.read_text()
    command = screensaver_command(original)[1]
    if state["launcher_command"] in command:
        restored = patch_command(original, state["launcher_command"], STOCK_LAUNCHER)
        atomic_write(service, restored, service.stat().st_mode & 0o777)
    elif STOCK_LAUNCHER not in command:
        fail("idle launcher was customized after installation; restore its command before uninstalling")
    if state["created_clone"] and tree_hash(plugin_dir) == state["original_tree_hash"]:
        run("omarchy", "plugin", "remove", state["plugin_id"], "--yes")
    else:
        print("Preserved your idle clone and its customizations; restored its original screensaver launcher.")
    run("omarchy-restart-shell")
    state_path.unlink()
    print("MatrixCode Omarchy integration removed. Original backup remains beside its saved state.")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("install", "uninstall", "status"), nargs="?", default="install")
    parser.add_argument("--launcher", help="absolute path to an installed screensaver launcher beside MatrixCode")
    args = parser.parse_args()
    # The official Omarchy plugin commands deliberately use ~/.config, not XDG_CONFIG_HOME.
    plugins_dir = Path.home() / ".config/omarchy/plugins"
    state_path = Path(os.environ.get("XDG_STATE_HOME", str(Path.home() / ".local/state"))) / "matrixcode/omarchy/integration.json"
    try:
        if args.action == "install":
            install(args, state_path, plugins_dir)
        elif args.action == "uninstall":
            uninstall(state_path, plugins_dir)
        elif state_path.exists():
            state = read_json(state_path)
            service = integration_service(state, plugins_dir)
            if state["launcher_command"] not in screensaver_command(service.read_text())[1]:
                fail("saved integration differs from the idle plugin; inspect it before reinstalling")
            suffix = " Shell restart pending; rerun install." if state.get("restart_pending") else ""
            print(f"Installed through idle clone {state['plugin_id']} with launcher {state['launcher_command']}.{suffix}")
        else:
            print("MatrixCode Omarchy integration is not installed.")
    except (RuntimeError, OSError, ValueError, KeyError) as error:
        print(f"MatrixCode Omarchy: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
