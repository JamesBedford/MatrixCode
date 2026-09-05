# Matrix Code for Ubuntu Linux

This directory contains the independent native Linux implementation of Matrix
Code. It is a C++20, Qt 6 Widgets, and OpenGL 3.3 Core application; it does not
embed HTML, JavaScript, WebGL, or a browser runtime.

The build produces `MatrixCode`, a resizable standalone application with native
settings, fullscreen and continuous multi-monitor presentation, and an
XScreenSaver-compatible playback mode. Ubuntu 24.04 LTS on arm64 and amd64 is
the release baseline.

## Architecture

The Linux targets compile the portable C++ core used by the Windows native
version. This makes packed rain state, RNG order, frame stepping, overlap lanes,
adaptive resolution, settings sanitization, intro timing, tokens, holiday and
full-moon rules, messages, image scheduling/reveal math, and display topology
the same code rather than another translation.

`MatrixCodeRenderGL` consumes that state through a hardware OpenGL context. Its
render graph uses an RGBA16F scene whose alpha carries bloom energy, floating
point image influence, one to three Gaussian bloom levels, additive bloom, ACES
tone mapping, scanlines, and vignette. Qt supplies the Wayland/X11 application
host, HiDPI screen geometry, native controls, accessible dialogs, text and glyph
rasterization, image decoding, and desktop integration.

One session advances one virtual-grid simulation for every monitor. Separate
fullscreen windows render slices of that grid, so glyphs, messages, and images
remain continuous across asymmetric monitor arrangements.

## Build and test

Install the Ubuntu build dependencies:

```sh
sudo apt install build-essential cmake ninja-build qt6-base-dev \
  qt6-image-formats-plugins fonts-noto-cjk libgl1-mesa-dev libegl1-mesa-dev \
  libx11-dev libxss-dev
```

Then use the repository commands:

```sh
npm run build:linux
npm run test:linux
npm run verify:linux
npm run release:linux
```

The equivalent direct CMake workflow is:

```sh
cd linux/MatrixCode
cmake --preset linux-debug
cmake --build --preset linux-debug
ctest --preset linux-debug
```

Release packaging uses CPack and writes an architecture-native `.deb` below the
release build directory. Release automation must build and test separate arm64
and amd64 artifacts; producing one architecture does not validate the other.

## Running

```sh
MatrixCode                         # windowed application
MatrixCode --settings              # settings only
MatrixCode --multi-monitor         # one continuous fullscreen display wall
MatrixCode --screensaver           # fullscreen saver-style playback
MatrixCode -root                   # conventional XScreenSaver root playback alias
MatrixCode --root                  # normalized alias emitted by XScreenSaver 6
MatrixCode --window-id WINDOW_ID   # XScreenSaver preview/window embedding on X11
MatrixCode -window-id WINDOW_ID    # conventional XScreenSaver preview alias
MatrixCode --capture output.png    # deterministic renderer capture
```

The standalone shortcuts match the other versions: `H` settings, `I` intro,
`M` messages, `X` images, `C` countdown, `N`/`Shift-M` messages, `Shift-X`
images, `P` pause, `Alt-F` diagnostics, `-`/`=` density, and `F`/`F11`
fullscreen. Double-click enters fullscreen; triple-click starts coordinated
multi-monitor mode; `Escape` first skips an active intro and then leaves the
current presentation surface.

Settings use the same versioned `mx-*` JSON document as Windows and are written
atomically to the Qt application-config directory, normally
`~/.config/MatrixCode/settings.json`.

## Screen saver integration

On X11, run `scripts/install-xscreensaver.sh` to install the current release
binary for the user and register its `--root` command with XScreenSaver.
The Debian package also installs desktop and XScreenSaver metadata.
XScreenSaver's generated settings panel only controls its software-rendering
override; launch `MatrixCode --settings` for the complete native rain, intro,
messages, images, and countdown configuration.

Stock GNOME on Wayland has no supported extension point for third-party secure
lock-screen renderers or live desktop wallpapers. MatrixCode therefore does not
replace, patch, or weaken the GNOME lock screen. The application, fullscreen,
and continuous multi-monitor modes remain available on Wayland with the full
renderer and feature set; XScreenSaver embedding is an X11-only integration.

## Validation boundary

Packed simulation results are byte-exact across native platforms. Live pixels
cannot be promised bit-identical across OpenGL drivers, text rasterizers, font
packages, and display color profiles. Canonical captures fix the seed, epoch,
font, grid, scale, and color space with adaptive resolution disabled, then use
the repository parity threshold: no structural difference, SSIM of at least
0.999, and at least 99.5% of channel values within 2/255. Ubuntu release claims
also require NVIDIA hardware and Mesa fallback runs, Wayland and X11 checks,
mixed-DPI/mixed-refresh tests, suspend/resume, monitor hot-plug, and `.deb`
install/upgrade/uninstall verification on both architectures.
