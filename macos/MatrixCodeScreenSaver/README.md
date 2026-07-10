# MatrixCode for macOS

`MatrixCode.saver` is an independent, Apple-Silicon macOS 13+ implementation of
MatrixCode. Playback uses AppKit, ScreenSaver.framework, and Metal. Its Options
sheet is native AppKit. The bundle contains no TypeScript, HTML, WebGL,
JavaScript runtime, or WKWebView.

The web and macOS versions intentionally remain separate products. They share
the same feature contract and persisted JSON keys, but the screen saver does
not build, embed, or execute the web app.

## Requirements

- macOS 13 or later on Apple Silicon
- Xcode and the Xcode command-line tools
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`)

## Build and test

From this directory:

```sh
./test.sh
./build.sh
```

The release products are written to `build/MatrixCode.saver` and
`build/MatrixCode.saver.zip`. The zip is copied directly from Xcode's signed
temporary output and is the safest artifact to move out of a cloud-synced
working tree.

## Install

```sh
./install.sh
```

Alternatively, expand `build/MatrixCode.saver.zip` outside the cloud-synced
working tree and double-click the resulting saver. Select **MatrixCode** in
System Settings → Screen Saver. Use **Options…** to edit the rain controls,
viewer name, intro, in-rain messages, and countdown/countup moments.

The Options sheet is transactional: **OK** saves all changes and **Cancel**
discards them. During normal screen-saver playback, macOS treats mouse and
keyboard input as an exit request, so fullscreen and multi-display presentation
are automatic rather than gesture-driven.

## Troubleshooting

- If System Settings has cached an older build, remove
  `~/Library/Screen Savers/MatrixCode.saver`, quit System Settings, and reinstall.
- If the preview stays on an older version, run `./install.sh` again; it clears
  extended attributes, re-signs the local bundle, and replaces the installed copy.
- Metal is required. The current project targets Apple Silicon Macs, all of
  which provide the required Metal feature set.
