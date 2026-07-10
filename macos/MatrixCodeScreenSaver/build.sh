#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
DERIVED_DATA="/private/tmp/MatrixCodeScreenSaverDerivedData"
PACKAGE_DIR="/private/tmp/MatrixCodeScreenSaverPackage"
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
for PRODUCT in "${SOURCE_SAVER}" "${SOURCE_APP}"; do
  if [[ ! -f "${PRODUCT}/Contents/Resources/MatrixCodeShaders.msl" ]]; then
    echo "error: ${PRODUCT:t} is missing the native Metal shader resource."
    exit 1
  fi
done
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
  "${SCRIPT_DIR}/build/MatrixCode.app.zip" \
  "${PACKAGE_DIR}"
mkdir -p "${PACKAGE_DIR}"
ditto "${SOURCE_SAVER}" "${PACKAGE_DIR}/MatrixCode.saver"
ditto "${SOURCE_APP}" "${PACKAGE_DIR}/MatrixCode.app"
xattr -cr "${PACKAGE_DIR}/MatrixCode.saver"
xattr -cr "${PACKAGE_DIR}/MatrixCode.app"
touch "${PACKAGE_DIR}/MatrixCode.saver"
touch "${PACKAGE_DIR}/MatrixCode.app"
codesign --force --sign - "${PACKAGE_DIR}/MatrixCode.saver"
codesign --force --sign - "${PACKAGE_DIR}/MatrixCode.app"
codesign --verify --deep --strict "${PACKAGE_DIR}/MatrixCode.saver"
codesign --verify --deep --strict "${PACKAGE_DIR}/MatrixCode.app"
ditto -c -k --keepParent "${PACKAGE_DIR}/MatrixCode.saver" "${SCRIPT_DIR}/build/MatrixCode.saver.zip"
ditto -c -k --keepParent "${PACKAGE_DIR}/MatrixCode.app" "${SCRIPT_DIR}/build/MatrixCode.app.zip"
ditto "${PACKAGE_DIR}/MatrixCode.saver" "${SCRIPT_DIR}/build/MatrixCode.saver"
ditto "${PACKAGE_DIR}/MatrixCode.app" "${SCRIPT_DIR}/build/MatrixCode.app"

echo "Built MatrixCode.saver, MatrixCode.saver.zip, MatrixCode.app, and MatrixCode.app.zip in ${SCRIPT_DIR}/build"
