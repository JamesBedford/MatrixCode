#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
cd "${SCRIPT_DIR}"

xcodegen generate
xcodebuild \
  -project MatrixCodeScreenSaver.xcodeproj \
  -scheme MatrixCode \
  -configuration Debug \
  -derivedDataPath /private/tmp/MatrixCodeScreenSaverDerivedData \
  -destination "platform=macOS,arch=arm64" \
  -quiet \
  test
