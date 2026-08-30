# Matrix Code for Windows

This directory contains the independent native Windows implementation of Matrix
Code. It is C++20, Win32, Direct3D 11, Direct2D/DirectWrite, and WIC; it does not
embed HTML, TypeScript, WebGL, or a browser runtime.

The build produces:

- `MatrixCode.exe` — the resizable standalone application.
- `Matrix Code.scr` — a native Windows screen saver supporting `/s`, `/c`, and
  `/p <HWND>` shell modes.
- `MatrixCodeNativeTests.exe` — deterministic core/platform tests.
- `MatrixCodeRenderCapture.exe` — fixed WARP-backed PNG capture tool.

Windows 10 version 2004 (build 19041) or newer is the runtime baseline. Both
x64 and ARM64 are first-class release architectures.

## Architecture

`MatrixCodeCore` is platform-neutral and contains the locked RGBA8 rain state,
Mulberry32 random sequence, bounded frame stepping, overlap-lane and
adaptive-resolution controllers, mixed-DPI display topology, intro timeline,
token resolver, rain-message scheduler, settings sanitizers, compact image
masks, and deterministic image scheduling/reveal math. The golden checksums in
`tests/fixtures/core-golden.json` come from the web implementation.

`MatrixCodeRenderD3D11` consumes those packed states. Its render graph uses an
RGBA16F scene whose alpha channel carries the head/glint bloom signal, a
floating-point image-influence texture that preserves the full 1.45 HDR range,
one to three downsampled Gaussian bloom levels, additive bloom composite, ACES
tone mapping, scanlines, and vignette. DirectWrite builds the glyph atlas and
the post-composite typewriter/HUD surfaces; ambient rain glyphs may be mirrored
while the dedicated message range remains readable. The atlas uses the web
contract's 64-pixel cells and approximately 50-pixel glyph em size. Hardware
D3D11 is preferred and WARP is the recovery/fallback and deterministic-capture
path.

`MatrixCodeWin32` owns process/window policy. Screen-saver playback creates one
topmost window per physical monitor but advances one shared virtual-grid
simulation, so monitor slices do not drift. Preview mode creates one true child
window in the Control Panel preview HWND. The app and `.scr /c` share the same
settings surface and `%LOCALAPPDATA%\MatrixCode\settings.json` store. The
standalone app supports `F`/`F11` fullscreen, `H` settings, `P` pause, a
persisted `Alt-F` frame-rate/resolution HUD, and the web app's triple-click
multi-monitor launch. All monitor slices use one per-display logical topology so
grid seams remain anchored when display scale factors differ. A fresh shared
session seed keeps each multi-display launch continuous without repeating the
same rain, message RNG remains independent, and swap chains present without
serially blocking one another. Animated Windows playback is paced to 60 FPS on
both standard and high-refresh displays so startup and settled rain keep the same
presentation cadence.

The app, screen saver, and preview automatically use Red on February 14 and
Classic green on March 17, for the entire local Gregorian date each year. They
also use White for the entire local calendar day containing the astronomical
full-moon instant, before and after that instant. Fixed holiday colours take
precedence when the dates coincide. The shared lunar calculation is the same
approximation used by the `{countdown:fullmoon}` token, not a phase tolerance;
both full moons count when two fall in the same month.
Live OS date/timezone changes are checked before every playback tick, including
paused/reduced-motion ticks and the first tick after resuming. A one-day cache
uses actual local-calendar-day epoch boundaries, including 23/25-hour DST days.
A bounded UTC-to-local search finds the first valid instant of each date,
including skipped or repeated midnight. Resolved boundaries are cached by local
date and Windows timezone rules, avoiding stale CRT timezone state. The override
colours rain, messages, images, intro text, and themed toasts, and disables
Gold-only sparkle while active. Selected settings and custom colours remain
unchanged; the latest selection returns when the holiday ends. The fixed WARP
capture deliberately bypasses this live-date override to remain deterministic.

Standalone keyboard and pointer controls follow the browser contract:

- `H` opens settings; `I`, `M`, `X`, and `C` open the structured document pages;
- `N` or `Shift-M` toggles messages, and `Shift-X` toggles image reveals; a
  themed top-right status toast confirms those shortcut changes;
- `P` pauses/resumes, `Alt-F` toggles the persisted performance HUD, and
  `-`/`=` changes density;
- `F` or `F11` toggles fullscreen, double-click settles to fullscreen, and
  triple-click starts the coordinated multi-display host;
- `Escape` skips an intro, leaves ordinary fullscreen, or exits a coordinated
  multi-display presentation.

## Build and test

Prerequisites:

- Visual Studio 2022 with Desktop development with C++ and the Windows 10/11 SDK.
- CMake 3.29 or newer.
- WiX Toolset v4 only when producing MSI packages.

From a Visual Studio developer PowerShell:

```powershell
cmake --preset windows-x64
cmake --build --preset windows-x64-debug
ctest --test-dir out/build/windows-x64 -C Debug --output-on-failure
```

Release builds:

```powershell
./scripts/Build-Windows.ps1 -Architecture x64 -Configuration Release
./scripts/Build-Windows.ps1 -Architecture arm64 -Configuration Release
./scripts/Build-Release.ps1 -Version 0.1.0 -Publisher 'Your legal publisher' -RequireSigning
```

`Build-Release.ps1` signs the PE files before WiX consumes them, then signs each
MSI and emits per-architecture portable and PDB archives plus `SHA256SUMS.txt`.
Configure one signing backend:

- `MATRIXCODE_SIGN_PFX` and optionally `MATRIXCODE_SIGN_PFX_PASSWORD`;
- `MATRIXCODE_SIGN_SUBJECT` for a certificate already in the certificate store;
- `MATRIXCODE_SIGN_COMMAND` for Azure Trusted Signing or another managed signer.

Credentials must never be committed. Release mode with `-RequireSigning` fails
closed if no backend is configured.

## Install and screen-saver behavior

The architecture-specific WiX MSIs share one upgrade family, so switching architectures performs
a major upgrade instead of leaving conflicting component registrations. Each installs the app under native Program Files
and the `.scr` file under native System32. It intentionally does not overwrite
the user's current screen saver. After installation, open Windows Settings,
search for **Change screen saver**, and select **Matrix Code**. Uninstall keeps
the user's per-user settings.

For a development build, run `npm run install:windows` from the repository
root. `Install-ScreenSaver.ps1` builds the x64 Release target, requests
administrator access through UAC, backs up any different System32 copy under
`out/backups/`, installs and SHA-256-verifies the rebuilt `.scr`, selects it for
the current user, and opens Screen Saver Settings. Pass `-SkipBuild` directly
to the script to reinstall an existing staged build, `-Architecture arm64` for
an ARM64 build, or `-NoSettings` to leave the settings dialog closed.

The `.scr` command-line contract is:

- no arguments or `/c[:HWND]` — configuration window;
- `/s` — full screen, one coordinated window per display;
- `/p HWND` or `/p:HWND` — embedded Control Panel preview.

Keyboard, pointer-button, or mouse-wheel input exits `/s`; small synthetic
startup mouse moves are ignored. `/p` never applies those exit rules. Windows
itself owns password and lock-on-resume policy.

## Verification and remaining release gates

The native core carries the web golden simulation checksums and deterministic
tests for display topology, intro timing, tokens, messages, images, screen-saver
arguments, and settings. The renderer has a fixed WARP capture entry point. The
release gate must still compile and run the x64 tests/capture on a suitable
Windows host and the ARM64 tests/capture on Windows 11 ARM64 hardware. A release
is not visually approved until those captures are compared to the fixed web
capture using the same SSIM and per-channel thresholds.

Intro typewriting, token expansion, rain messages, image reveal (including its
full 1.45 HDR range), adaptive resolution, and per-display logical topology are
wired into the live host. The DPI-aware settings surface exposes the main
rain/renderer controls, structured reorderable Intro/Messages/Images/Countdown
editors, draft Intro Preview/Replay, a live countdown/countup token preview,
WIC-backed image import, section reset/apply flows, and a sanitized raw JSON
escape hatch. Multi-window playback uses nonblocking presentation so one slow
swap chain does not serially throttle every display.

The remaining gates are validation rather than known source-feature gaps. This
checkout still needs a Visual Studio build and native test/WARP-capture run on
x64, an ARM64 build and hardware run, Windows screen-saver shell validation, and
mixed-DPI/mixed-refresh capture comparison. Exact glyph pixels can vary with
installed DirectWrite font versions; a bundled, licensed font or an approved
capture tolerance is required before claiming pixel-identical output. Valid
Unicode text follows the shared scalar contract; a transient isolated UTF-16
surrogate entered in a Win32 edit control is normalized to U+FFFD when the
document is sanitized.

Wallpaper Engine is deliberately outside this directory. Its public Workshop
artifact must remain a web wallpaper built from the browser source of truth;
the native EXE is not used as its payload.
