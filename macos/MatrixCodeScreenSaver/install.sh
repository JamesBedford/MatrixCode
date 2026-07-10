#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
"${SCRIPT_DIR}/build.sh"

INSTALL_DIR="${HOME}/Library/Screen Savers"
mkdir -p "${INSTALL_DIR}"
SOURCE_SAVER="/private/tmp/MatrixCodeScreenSaverDerivedData/Build/Products/Release/MatrixCode.saver"
rm -rf "${INSTALL_DIR}/MatrixCode.saver"
ditto "${SOURCE_SAVER}" "${INSTALL_DIR}/MatrixCode.saver"
xattr -cr "${INSTALL_DIR}/MatrixCode.saver"
touch "${INSTALL_DIR}/MatrixCode.saver"
codesign --force --sign - "${INSTALL_DIR}/MatrixCode.saver"
codesign --verify --deep --strict "${INSTALL_DIR}/MatrixCode.saver"

if /usr/bin/killall legacyScreenSaver 2>/dev/null; then
  echo "Restarted macOS's cached legacy screen saver host."
fi

echo "Installed MatrixCode.saver. Select it in System Settings → Screen Saver."
