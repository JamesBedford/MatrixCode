#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_ROOT=${SCRIPT_DIR:h:h}
cd "${SCRIPT_DIR}"

. "${REPO_ROOT}/scripts/lib/xcode-developer-dir.sh"

DEVELOPER_DIR="$(matrixcode_resolve_developer_dir)" || exit 1
export DEVELOPER_DIR

xcodegen generate
"${DEVELOPER_DIR}/usr/bin/xcodebuild" \
  -project MatrixCodeScreenSaver.xcodeproj \
  -scheme MatrixCode \
  -configuration Debug \
  -derivedDataPath /private/tmp/MatrixCodeScreenSaverDerivedData \
  -destination "platform=macOS,arch=arm64" \
  -quiet \
  test
