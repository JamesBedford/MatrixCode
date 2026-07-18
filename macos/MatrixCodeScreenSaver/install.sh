#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
"${SCRIPT_DIR}/build.sh" --release

INSTALL_DIR="${HOME}/Library/Screen Savers"
mkdir -p "${INSTALL_DIR}"
SOURCE_SAVER="${SCRIPT_DIR}/build/Release/Matrix Code.saver"
rm -rf "${INSTALL_DIR}/Matrix Code.saver"
ditto "${SOURCE_SAVER}" "${INSTALL_DIR}/Matrix Code.saver"
xattr -cr "${INSTALL_DIR}/Matrix Code.saver"
touch "${INSTALL_DIR}/Matrix Code.saver"

# build.sh signs with the Developer ID identity when it is available. Re-signing
# unconditionally would replace that with an ad-hoc signature, so only sign here
# if what was copied does not verify.
if codesign --verify --deep --strict "${INSTALL_DIR}/Matrix Code.saver" 2>/dev/null; then
  echo "Preserved the existing signature."
else
  echo "Copied saver did not verify; ad-hoc signing it for local use."
  codesign --force --sign - "${INSTALL_DIR}/Matrix Code.saver"
  codesign --verify --deep --strict "${INSTALL_DIR}/Matrix Code.saver"
fi

if /usr/bin/killall legacyScreenSaver 2>/dev/null; then
  echo "Restarted macOS's cached legacy screen saver host."
fi

echo "Installed Matrix Code.saver. Select it in System Settings → Screen Saver."
