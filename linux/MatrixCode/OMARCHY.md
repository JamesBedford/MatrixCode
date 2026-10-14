# Matrix Code on Omarchy

MatrixCode uses its existing native C++20/Qt/OpenGL application on Omarchy.
The Arch package includes the application, settings editor, desktop entry,
and an optional adapter for Omarchy's idle screen saver. One process renders
one continuous simulation across all connected monitors.

## Target and dependencies

The integration targets current **Omarchy 4.0.4 on x86_64**, whose desktop uses
Hyprland and Quickshell. Its interfaces were checked against Omarchy's
[`v4.0.4` sources](https://github.com/omacom/omarchy/tree/v4.0.4) on
2026-10-14. The adapter checks the Omarchy 4 service interface before changing files.
Older releases with hypridle/hyprlock are not covered. Omarchy and Arch update continuously; record their installed
versions when reporting a problem.

Install the build tools and the recommended font/image packages:

```sh
sudo pacman -S --needed base-devel cmake ninja python qt6-base libglvnd \
  libx11 libxcb qt6-imageformats noto-fonts-cjk
```

The package targets Arch's Qt 6.10 or newer. Those releases include the
Wayland client/platform plugin in `qt6-base`; a separate `qt6-wayland`
dependency is not required for this application. See Arch's
[Qt Wayland dependency migration](https://archlinux.org/todo/qt6-wayland-dependency-cleanup/).
The Omarchy adapter also uses the desktop's `hyprctl` and Omarchy commands,
plus `flock`/`setsid` from `util-linux` and `pgrep` from `procps-ng`.

## Build and install

Run from the repository root as a normal user:

```sh
linux/MatrixCode/scripts/package-arch.sh
sudo pacman -U linux/MatrixCode/out/arch/matrixcode-*.pkg.tar.zst
MatrixCode
```

The script snapshots the checked-out Linux sources and the shared C++ core,
generates a checksummed `PKGBUILD`, then runs `makepkg` with native tests
enabled. It needs no Node runtime and does not install the package or change
desktop configuration. Files are written below `linux/MatrixCode/out/arch`.
An alternative output directory can be selected with `--output DIRECTORY`.

To review the source package without an Arch build host:

```sh
linux/MatrixCode/scripts/package-arch.sh --prepare-only
```

That produces the source archive and build recipe only; it does not validate
native compilation or graphics. No AUR submission or prebuilt Omarchy binary
is implied by this workflow. Ubuntu's `.deb` downloads are separate packages.

## Enable the idle screen saver

Install the package first, then run these commands as your desktop user from
an unlocked Omarchy session:

```sh
matrixcode-omarchy install
matrixcode-omarchy status
matrixcode-omarchy-screensaver force
```

Installation uses Omarchy's official idle-plugin clone mechanism. It replaces
only the launch command in a user-owned clone, retains the configured idle
and lock deadlines in `~/.config/omarchy/shell.json`, and restarts the shell
so its kept-loaded idle service uses the new command. The installer checks
the running shell and refuses to change configuration while locked or during
an active idle cycle. It records the original service for recovery under
the XDG state directory, normally `~/.local/state/matrixcode/omarchy`.

The launcher honors Omarchy's screen-saver toggle; `force` starts it even if
the idle saver is disabled. It starts one coordinated process with the
Wayland app ID `org.omarchy.screensaver`, which lets Omarchy track the windows
and terminate them when locking. Keyboard/pointer input dismisses the saver,
and the launcher restores the previously focused monitor when unlocked.
A hardware renderer failure returns exit status 75 to the launcher, which
retries once with `--software` while retaining process supervision.
The application uses the usual `~/.config/MatrixCode/settings.json` document;
run `MatrixCode --settings` to edit it.

This is an idle animation before the desktop locks. Omarchy supplies the
secure lock surface and authentication; MatrixCode does not render inside
that surface. The adapter does not use XScreenSaver or embed a Qt window in
a terminal.

To restore the stock launcher:

```sh
matrixcode-omarchy uninstall
```

Uninstallation removes a clone created by MatrixCode only when it is still
unchanged apart from the installed launch command. Existing or subsequently
customized user clones are retained, with only MatrixCode's command reversed.
Uninstall the integration before removing the application package.

An idle-plugin clone retains the service code from when it was created.
After upgrading Omarchy, run `matrixcode-omarchy uninstall` followed by
`matrixcode-omarchy install` to refresh an unchanged MatrixCode-created clone
from the new built-in service. A customized or pre-existing user clone is
preserved; merge upstream idle-service updates into that clone before
reinstalling the adapter.

Omarchy's supported user-plugin customization is documented in its
[plugin manual](https://github.com/omacom/omarchy/blob/v4.0.4/manual/32-shell-plugins.md).
The current
[idle service](https://github.com/omacom/omarchy/blob/v4.0.4/shell/plugins/services/idle/Service.qml),
[stock launcher](https://github.com/omacom/omarchy/blob/v4.0.4/bin/omarchy-launch-screensaver),
and [lock command](https://github.com/omacom/omarchy/blob/v4.0.4/bin/omarchy-system-lock)
define the integration contract.

## Verification and release boundary

Local implementation checks on 2026-10-14 passed the 500-test repository
suite (including 18 mocked Omarchy scenarios), the browser production build,
13,107 shared C++ assertions, and 26 saver-activity assertions compiled with
strict Clang warnings on macOS. Arch source staging, checksums, and script
syntax/lint checks also passed. No native Arch/Qt build, `makepkg` package,
GPU capture, or live Omarchy session was available for this verification.

The packaging recipe runs the Linux CTest suites, including the shared native
simulation tests, Qt platform/UI tests, Arch source/staging tests, and Omarchy
installer/launcher tests. The latter use mocked desktop commands to exercise
installation, restoration, toggles, identity, duplicate launches, and process
cleanup. They do not launch a live Hyprland session.

The integration tests can also run independently:

```sh
python3 linux/MatrixCode/tests/OmarchyIntegrationTests.py
bash linux/MatrixCode/tests/ArchPackagingTests.sh "$PWD"
```

Before calling an Omarchy binary a validated release, check it on an actual
Omarchy machine: native compile and all CTest suites; package install, upgrade,
and removal; deterministic rendering against the parity contract; NVIDIA and
Mesa rendering; one and multiple monitors with fractional scaling and mixed
refresh rates; input dismissal and focus restoration; disabled/forced saver;
unchanged idle lock timing; suspend/resume; and monitor hot-plug. Preserve the
existing Ubuntu/X11 checks when changing shared Linux code. Native graphics
and desktop integration require that environment even when the mocked tests
pass elsewhere.
