#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
DERIVED_DATA="/private/tmp/MatrixCodeScreenSaverDerivedData"
cd "${SCRIPT_DIR}"

xcodegen generate
xcodebuild \
  -project MatrixCodeScreenSaver.xcodeproj \
  -scheme MatrixCode \
  -configuration Release \
  -derivedDataPath "${DERIVED_DATA}" \
  -destination "platform=macOS,arch=arm64" \
  -quiet \
  build

SOURCE_SAVER="${DERIVED_DATA}/Build/Products/Release/MatrixCode.saver"
SOURCE_APP="${DERIVED_DATA}/Build/Products/Release/MatrixCode.app"
codesign --verify --deep --strict "${SOURCE_SAVER}"
codesign --verify --deep --strict "${SOURCE_APP}"
if otool -L "${SOURCE_SAVER}/Contents/MacOS/MatrixCode" | grep -q WebKit ||
   otool -L "${SOURCE_APP}/Contents/MacOS/MatrixCode" | grep -q WebKit; then
  echo "error: Native macOS products unexpectedly link WebKit."
  exit 1
fi
if find "${SOURCE_SAVER}" "${SOURCE_APP}" -type f \( -name '*.html' -o -name '*.js' -o -name '*.ts' \) | grep -q .; then
  echo "error: Native macOS products unexpectedly contain web source or assets."
  exit 1
fi
mkdir -p "${SCRIPT_DIR}/build"
rm -rf \
  "${SCRIPT_DIR}/build/MatrixCode.saver" \
  "${SCRIPT_DIR}/build/MatrixCode.saver.zip" \
  "${SCRIPT_DIR}/build/MatrixCode.app" \
  "${SCRIPT_DIR}/build/MatrixCode.app.zip"
ditto "${SOURCE_SAVER}" "${SCRIPT_DIR}/build/MatrixCode.saver"
ditto "${SOURCE_APP}" "${SCRIPT_DIR}/build/MatrixCode.app"
xattr -cr "${SCRIPT_DIR}/build/MatrixCode.saver"
xattr -cr "${SCRIPT_DIR}/build/MatrixCode.app"
touch "${SCRIPT_DIR}/build/MatrixCode.saver"
touch "${SCRIPT_DIR}/build/MatrixCode.app"
codesign --force --sign - "${SCRIPT_DIR}/build/MatrixCode.saver"
codesign --force --sign - "${SCRIPT_DIR}/build/MatrixCode.app"
codesign --verify --deep --strict "${SCRIPT_DIR}/build/MatrixCode.saver"
codesign --verify --deep --strict "${SCRIPT_DIR}/build/MatrixCode.app"
ditto -c -k --keepParent "${SOURCE_SAVER}" "${SCRIPT_DIR}/build/MatrixCode.saver.zip"
ditto -c -k --keepParent "${SOURCE_APP}" "${SCRIPT_DIR}/build/MatrixCode.app.zip"

echo "Built MatrixCode.saver, MatrixCode.saver.zip, MatrixCode.app, and MatrixCode.app.zip in ${SCRIPT_DIR}/build"
