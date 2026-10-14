#!/usr/bin/env python3
"""Exercise Omarchy integration against isolated desktop-command mocks."""
import json
import importlib.util
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from unittest import mock

PROJECT = Path(__file__).resolve().parents[1]
INSTALLER = PROJECT / "scripts/install-omarchy.py"
LAUNCHER = PROJECT / "resources/omarchy/matrixcode-omarchy-screensaver"
STOCK_SERVICE = '''import QtQuick
Item {
  readonly property string screensaverClass: "org.omarchy.screensaver"
  readonly property int defaultLockSeconds: 300
  function launchScreensaver() {
    runProcess(screensaverProcess, "screensaver", "[[ $(omarchy-shell lock isLocked 2>/dev/null) == \\"true\\" ]] || omarchy-launch-screensaver")
  }
  function lockSystem() { runProcess(lockProcess, "lock", "omarchy-system-lock") }
}
'''
MOCK = r'''#!/usr/bin/env python3
import fcntl, json, os, pathlib, shutil, signal, subprocess, sys, time
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(os.environ["MOCK_ROOT"])
with (root / "commands").open("a") as log:
    log.write(json.dumps([name, *args]) + "\n")
if name == "omarchy-shell":
    if args == ["lock", "status"]:
        print(json.dumps({"secure": os.environ.get("LOCKED") == "1", "requested": os.environ.get("LOCK_REQUESTED") == "1"}))
    elif args == ["lock", "isLocked"]:
        print("true" if os.environ.get("LOCKED") == "1" else "false")
    elif args == ["idle", "status"]:
        print(json.dumps({"inIdleCycle": os.environ.get("IDLED") == "1"}))
    else: sys.exit(1)
elif name == "omarchy":
    plugins = pathlib.Path(os.environ["HOME"]) / ".config/omarchy/plugins"
    if args == ["plugin", "list", "--json"]:
        rows = [{"id": "omarchy.idle", "enabled": not (root / "cloned").exists()}]
        for manifest in plugins.glob("*/manifest.json"):
            if manifest.parent.name.startswith("."): continue
            rows.append({"id": json.loads(manifest.read_text())["id"], "enabled": True})
        print(json.dumps(rows))
    elif args == ["plugin", "clone", "omarchy.idle"]:
        target = plugins / "tester.idle"
        shutil.copytree(root / "omarchy/shell/plugins/services/idle", target)
        manifest = json.loads((target / "manifest.json").read_text())
        manifest.update({"id": "tester.idle", "omarchy": {"clonedFrom": "omarchy.idle"}})
        (target / "manifest.json").write_text(json.dumps(manifest))
        (root / "cloned").touch()
        if os.environ.get("CLONE_FAILURE") == "1": sys.exit(1)
    elif len(args) == 4 and args[:2] == ["plugin", "remove"] and args[3] == "--yes":
        shutil.move(str(plugins / args[2]), str(plugins / ("." + args[2] + ".backup")))
        (root / "cloned").unlink(missing_ok=True)
    else: sys.exit(1)
elif name == "omarchy-restart-shell":
    sys.exit(int(os.environ.get("RESTART_FAILURE", "0")))
elif name == "omarchy-toggle-enabled":
    sys.exit(0 if os.environ.get("SAVER_DISABLED") == "1" else 1)
elif name == "omarchy-hyprland-monitor-focused":
    print("DP-2")
elif name == "hyprctl":
    if os.environ.get("MODERN_FOCUS_FAILURE") == "1" and len(args) == 2: sys.exit(1)
elif name == "pgrep":
    sys.exit(0 if os.environ.get("ALREADY_RUNNING") == "1" else 1)
elif name == "flock":
    try: fcntl.flock(int(args[-1]), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError: sys.exit(1)
elif name == "env":
    if args[0] != "--default-signal=HUP,INT,TERM": sys.exit(1)
    args.pop(0)
    for signum in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM): signal.signal(signum, signal.SIG_DFL)
    key, value = args.pop(0).split("=", 1)
    os.environ[key] = value
    os.execvp(args[0], args)
elif name == "setsid":
    os.setsid()
    os.execvp(args[0], args)
elif name == "MatrixCode":
    with (root / "launches").open("a") as log: log.write(json.dumps({"args": args, "platform": os.environ.get("QT_QPA_PLATFORM"), "pid": os.getpid()}) + "\n")
    if os.environ.get("GPU_FAILURE") == "1" and "--software" not in args: sys.exit(75)
    if os.environ.get("SPAWN_HELPER") == "1":
        helper = "import os, pathlib, signal, sys, time; r=pathlib.Path(os.environ['MOCK_ROOT']); signal.signal(signal.SIGTERM, lambda *_: (r.joinpath('helper-terminated').touch(), sys.exit(0))); r.joinpath('helper-running').touch(); time.sleep(30)"
        subprocess.Popen([sys.executable, "-c", helper])
    if os.environ.get("HOLD_APP") == "1":
        (root / "app-running").touch()
        def terminated(signum, frame):
            (root / "app-terminated").touch()
            sys.exit(0)
        signal.signal(signal.SIGTERM, terminated)
        while not (root / "dismiss").exists(): time.sleep(0.02)
    sys.exit(0)
'''


class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="matrixcode-omarchy-")
        self.root = Path(self.temporary.name)
        self.home = self.root / "home"
        self.bin = self.root / "bin"
        self.home.mkdir()
        self.bin.mkdir()
        self.env = dict(os.environ, HOME=str(self.home), USER="tester", MOCK_ROOT=str(self.root),
                        OMARCHY_PATH=str(self.root / "omarchy"), XDG_STATE_HOME=str(self.root / "state"),
                        XDG_RUNTIME_DIR=str(self.root), HYPRLAND_INSTANCE_SIGNATURE="mock",
                        PATH=str(self.bin) + os.pathsep + os.environ["PATH"])
        for key in ("LOCKED", "LOCK_REQUESTED", "IDLED", "SAVER_DISABLED", "ALREADY_RUNNING", "GPU_FAILURE", "HOLD_APP", "RESTART_FAILURE", "MODERN_FOCUS_FAILURE", "CLONE_FAILURE", "SPAWN_HELPER"):
            self.env.pop(key, None)
        mock_path = self.bin / "mock-desktop-command"
        mock_path.write_text(MOCK.replace("#!/usr/bin/env python3", "#!" + os.sys.executable, 1))
        mock_path.chmod(0o755)
        for name in ("omarchy", "omarchy-shell", "omarchy-restart-shell", "omarchy-toggle-enabled",
                     "omarchy-hyprland-monitor-focused", "hyprctl", "pgrep", "flock", "setsid", "env", "MatrixCode"):
            path = self.bin / name
            path.symlink_to(mock_path.name)
        self.launcher = self.bin / LAUNCHER.name
        shutil.copy2(LAUNCHER, self.launcher)
        self.stock = self.root / "omarchy/shell/plugins/services/idle"
        self.stock.mkdir(parents=True)
        (self.root / "omarchy/version").write_text("4.0.0\n")
        (self.stock / "Service.qml").write_text(STOCK_SERVICE)
        (self.stock / "IdleModel.js").write_text("// stock idle math\n")
        (self.stock / "manifest.json").write_text(json.dumps({"id": "omarchy.idle", "kinds": ["service"],
                                                             "keepLoaded": True, "entryPoints": {"service": "Service.qml"}}))
        self.plugin = self.home / ".config/omarchy/plugins/tester.idle"
        self.state = self.root / "state/matrixcode/omarchy/integration.json"
        self.children = []

    def tearDown(self):
        for child in self.children:
            if child.poll() is None:
                child.terminate()
                child.wait(timeout=5)
            if child.stdout: child.stdout.close()
            if child.stderr: child.stderr.close()
        self.temporary.cleanup()

    def install(self, *args, success=True, **environment):
        result = subprocess.run([os.sys.executable, str(INSTALLER), *args], env=dict(self.env, **environment),
                                text=True, capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def launch(self, *args, success=True, **environment):
        result = subprocess.run([str(self.launcher), *args], env=dict(self.env, **environment),
                                text=True, capture_output=True, timeout=30)
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def rows(self, name):
        path = self.root / name
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def wait_for(self, path):
        deadline = time.monotonic() + 15
        while not path.exists() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertTrue(path.exists(), f"timed out waiting for {path}")

    def test_install_clone_preserves_lock_timing_and_is_reversible(self):
        self.install("install")
        content = (self.plugin / "Service.qml").read_text()
        self.assertIn(str(self.launcher), content)
        self.assertIn("defaultLockSeconds: 300", content)
        self.assertIn('"omarchy-system-lock"', content)
        self.assertEqual((self.stock / "Service.qml").read_text(), STOCK_SERVICE)
        first = content
        self.install("install")
        self.assertEqual((self.plugin / "Service.qml").read_text(), first)
        self.install("status")
        self.install("uninstall")
        self.assertFalse(self.plugin.exists())
        self.assertFalse(self.state.exists())
        backup = self.plugin.parent / ".tester.idle.backup/Service.qml"
        self.assertEqual(backup.read_text(), STOCK_SERVICE)
        self.assertIn(["omarchy", "plugin", "remove", "tester.idle", "--yes"], self.rows("commands"))

    def test_preserves_existing_idle_clone_and_later_customizations(self):
        self.install("install")
        self.install("uninstall")
        shutil.move(str(self.plugin.parent / ".tester.idle.backup"), self.plugin)
        (self.root / "cloned").touch()
        content = STOCK_SERVICE + "// user customization\n"
        (self.plugin / "Service.qml").write_text(content)
        self.install("install")
        (self.plugin / "IdleModel.js").write_text("// a later user customization\n")
        self.install("uninstall")
        self.assertEqual((self.plugin / "Service.qml").read_text(), content)
        self.assertEqual((self.plugin / "IdleModel.js").read_text(), "// a later user customization\n")

    def test_new_clone_with_later_customization_is_retained(self):
        self.install("install")
        (self.plugin / "extra.txt").write_text("user data")
        self.install("uninstall")
        self.assertEqual((self.plugin / "extra.txt").read_text(), "user data")
        self.assertEqual((self.plugin / "Service.qml").read_text(), STOCK_SERVICE)

    def test_locked_requested_or_idle_session_refuses_without_changes(self):
        for environment in ({"LOCKED": "1"}, {"LOCK_REQUESTED": "1"}, {"IDLED": "1"}):
            self.install("install", success=False, **environment)
            self.assertFalse(self.plugin.exists())
            self.assertFalse(self.state.exists())

    def test_unknown_version_or_command_refuses_before_cloning(self):
        (self.root / "omarchy/version").write_text("3.8.5\n")
        self.install("install", success=False)
        self.assertFalse(self.plugin.exists())
        (self.root / "omarchy/version").write_text("4.0.0\n")
        (self.stock / "Service.qml").write_text(STOCK_SERVICE.replace("omarchy-launch-screensaver", "user-saver"))
        self.install("install", success=False)
        self.assertFalse(self.plugin.exists())

    def test_launcher_path_with_spaces_is_quoted_and_reversible(self):
        target = self.root / "installed \"binaries\""
        shutil.copytree(self.bin, target)
        self.install("install", "--launcher", str(target / LAUNCHER.name))
        self.assertIn("'", (self.plugin / "Service.qml").read_text())
        self.install("uninstall")
        self.assertFalse(self.state.exists())

    def test_launcher_single_coordinated_wayland_process_and_focus_restore(self):
        self.launch()
        rows = self.rows("launches")
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["args"], ["--screensaver", "--multi-monitor", "--app-id", "org.omarchy.screensaver"])
        self.assertEqual(rows[0]["platform"], "wayland")
        self.assertIn(["hyprctl", "dispatch", 'hl.dsp.focus({ monitor = "DP-2" })'], self.rows("commands"))

    def test_toggle_force_existing_saver_and_lock_refusal(self):
        self.launch(success=False, SAVER_DISABLED="1")
        self.assertEqual(self.rows("launches"), [])
        self.launch("force", SAVER_DISABLED="1")
        self.assertEqual(len(self.rows("launches")), 1)
        self.launch(ALREADY_RUNNING="1")
        self.assertEqual(len(self.rows("launches")), 1)
        self.launch("force", success=False, LOCKED="1")
        self.launch("force", success=False, LOCK_REQUESTED="1")
        self.assertEqual(len(self.rows("launches")), 1)

    def test_flock_rejects_concurrent_launches_and_input_dismissal_restores_focus(self):
        first = subprocess.Popen([str(self.launcher)], env=dict(self.env, HOLD_APP="1"),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.children.append(first)
        self.wait_for(self.root / "app-running")
        self.launch()
        self.assertEqual(len(self.rows("launches")), 1)
        (self.root / "dismiss").touch()
        self.assertEqual(first.wait(timeout=15), 0)
        self.assertIn(["hyprctl", "dispatch", 'hl.dsp.focus({ monitor = "DP-2" })'], self.rows("commands"))

    def test_launcher_forwards_termination_and_waits_for_child(self):
        first = subprocess.Popen([str(self.launcher)], env=dict(self.env, HOLD_APP="1"),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.children.append(first)
        self.wait_for(self.root / "app-running")
        first.send_signal(signal.SIGTERM)
        self.assertEqual(first.wait(timeout=15), 143)
        self.assertTrue((self.root / "app-terminated").exists())
        self.assertIn(["hyprctl", "dispatch", 'hl.dsp.focus({ monitor = "DP-2" })'], self.rows("commands"))

    def test_state_write_failure_does_not_patch_service_and_restores_builtin(self):
        specification = importlib.util.spec_from_file_location("matrixcode_omarchy_installer", INSTALLER)
        installer = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(installer)
        original_write = installer.atomic_write
        def fail_state_write(path, *arguments, **keywords):
            if path == self.state:
                raise OSError("mock state write failure")
            return original_write(path, *arguments, **keywords)
        with mock.patch.dict(os.environ, self.env, clear=True), mock.patch.object(installer, "atomic_write", fail_state_write):
            with self.assertRaises(OSError):
                installer.install(type("Arguments", (), {"launcher": None})(), self.state, self.plugin.parent)
        self.assertFalse(self.state.exists())
        self.assertFalse(self.plugin.exists())
        self.assertEqual((self.plugin.parent / ".tester.idle.backup/Service.qml").read_text(), STOCK_SERVICE)

    def test_clone_failure_after_switch_rolls_back_and_can_retry(self):
        self.install("install", success=False, CLONE_FAILURE="1")
        self.assertFalse(self.plugin.exists())
        self.assertFalse(self.state.exists())
        self.assertIn(["omarchy", "plugin", "remove", "tester.idle", "--yes"], self.rows("commands"))
        self.install("install")
        self.install("uninstall")

    def test_lock_killing_renderer_also_cleans_up_helpers(self):
        first = subprocess.Popen([str(self.launcher)], env=dict(self.env, HOLD_APP="1", SPAWN_HELPER="1"),
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.children.append(first)
        self.wait_for(self.root / "helper-running")
        self.wait_for(self.root / "app-running")
        os.kill(self.rows("launches")[0]["pid"], signal.SIGTERM)
        first.wait(timeout=15)
        self.wait_for(self.root / "helper-terminated")

    def test_restart_failure_keeps_recovery_state_and_retries(self):
        self.install("install", success=False, RESTART_FAILURE="1")
        self.assertTrue(json.loads(self.state.read_text())["restart_pending"])
        self.assertIn("restart pending", self.install("status").stdout)
        self.install("install")
        self.assertFalse(json.loads(self.state.read_text())["restart_pending"])
        self.install("uninstall")

    def test_uninstall_restart_failure_retains_state_and_retries_restart(self):
        self.install("install")
        self.install("uninstall", success=False, RESTART_FAILURE="1")
        self.assertFalse(self.plugin.exists())
        self.assertTrue(self.state.exists())
        self.install("uninstall")
        self.assertFalse(self.state.exists())

    def test_status_detects_customized_command_and_uninstall_preserves_it(self):
        self.install("install")
        path = self.plugin / "Service.qml"
        state = json.loads(self.state.read_text())
        customized = path.read_text().replace(state["launcher_command"], "custom-saver")
        path.write_text(customized)
        self.install("status", success=False)
        self.install("uninstall", success=False)
        self.assertEqual(path.read_text(), customized)
        self.assertTrue(self.state.exists())

    def test_focus_restoration_supports_legacy_fallback(self):
        self.launch(MODERN_FOCUS_FAILURE="1")
        commands = self.rows("commands")
        self.assertIn(["hyprctl", "dispatch", 'hl.dsp.focus({ monitor = "DP-2" })'], commands)
        self.assertIn(["hyprctl", "dispatch", "focusmonitor", "DP-2"], commands)

    def test_renderer_software_retry_remains_one_coordinated_process(self):
        self.launch(GPU_FAILURE="1")
        rows = self.rows("launches")
        self.assertEqual(len(rows), 2)
        self.assertNotIn("--software", rows[0]["args"])
        self.assertIn("--software", rows[1]["args"])
        self.assertIn("--multi-monitor", rows[1]["args"])


if __name__ == "__main__":
    unittest.main()
