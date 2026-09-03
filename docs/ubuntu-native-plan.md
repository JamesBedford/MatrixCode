# Ubuntu native implementation plan

MatrixCode for Ubuntu is a native C++20 application using Qt 6 Widgets and an
OpenGL 3.3 Core render backend. It targets Ubuntu 24.04 LTS on arm64 and amd64,
with Wayland and X11 as first-class window-system backends.

## Architecture

- Reuse the portable `MatrixCodeCore` implementation currently housed under
  `windows/MatrixCode` for byte-exact rain, controllers, documents, tokens,
  messages, images, holiday rules, and display topology. Linux does not fork
  these algorithms.
- Drive one shared simulation/session for every display. Each fullscreen window
  renders a logical slice of the same virtual grid.
- Render to an RGBA16F scene with the established alpha bloom signal, followed
  by one to three bright-pass/blur levels, additive bloom, ACES tone mapping,
  scanlines, and vignette. State stays RGBA8 and image influence stays floating
  point so the 1.45 HDR reveal range is preserved.
- Use Qt for Wayland/X11 windows, HiDPI monitor discovery, native accessibility,
  settings and structured document editors, image decoding, and desktop
  integration. OpenGL resource creation remains isolated from the UI.
- Store the same versioned `mx-*` snapshot atomically below
  `QStandardPaths::AppConfigLocation`, with bounded reads and inter-process
  locking.

## Product surfaces

The Linux build provides a resizable app, fullscreen presentation, continuous
multi-monitor presentation, live native settings, Intro/Messages/Images/
Countdown editors, all established shortcuts, reduced motion, pause/HUD/toasts,
deterministic capture, `.deb` packaging, desktop/AppStream metadata, and an
XScreenSaver-compatible X11 launch mode.

GNOME Wayland deliberately has no supported third-party secure lock-screen or
live-wallpaper API. MatrixCode therefore never replaces or bypasses the system
lock screen. The standalone and multi-monitor app retain full render and feature
parity on Wayland; XScreenSaver integration is available on X11.

## Verification gates

1. GCC and Clang builds with strict warnings and no fast math on arm64/amd64.
2. Byte-exact shared native golden tests for simulation and schedulers.
3. Linux tests for CLI parsing, persistence, image masks, monitor geometry, and
   settings models.
4. Deterministic offscreen OpenGL capture plus the documented cross-backend
   visual threshold (no structural difference, SSIM >= 0.999, and at least
   99.5% of channels within 2/255 under fixed inputs).
5. NVIDIA hardware runs on the DGX Spark and Mesa software fallback runs.
6. Ubuntu GNOME Wayland/X11, mixed-DPI/mixed-refresh, hot-plug, suspend/resume,
   context recovery, and every editor/shortcut/lifecycle path.
7. Clean `.deb` install, upgrade, and uninstall on arm64 and amd64.
