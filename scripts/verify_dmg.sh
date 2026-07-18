#!/usr/bin/env bash
#
# Structural check of a built MatrixCode DMG. Mounts it, asserts it carries both
# products and the styling files, then detaches.
#
# Usage: ./scripts/verify_dmg.sh path/to/MatrixCode.dmg

set -euo pipefail

DMG="${1:?Usage: verify_dmg.sh <path-to-dmg>}"
[[ -f "${DMG}" ]] || { printf 'No such DMG: %s\n' "${DMG}" >&2; exit 1; }

TEMP_ROOT=""
MOUNT=""
cleanup() {
    if [[ -n "${MOUNT}" && -d "${MOUNT}" ]]; then
        hdiutil detach "${MOUNT}" -quiet 2>/dev/null \
            || hdiutil detach "${MOUNT}" -force -quiet 2>/dev/null || true
    fi
    [[ -z "${TEMP_ROOT}" || ! -d "${TEMP_ROOT}" ]] || rm -rf "${TEMP_ROOT}"
}
trap cleanup EXIT

# Mount at a private mountpoint rather than letting the volume land in /Volumes.
# A volume named "Matrix Code" that is already mounted — typically the previous
# build's DMG still open in Finder — would otherwise push this one to
# "/Volumes/Matrix Code 1" and make the mount path useless for identifying it.
TEMP_ROOT="$(mktemp -d)"
MOUNT="${TEMP_ROOT}/mnt"
mkdir -p "${MOUNT}"
hdiutil attach "${DMG}" -nobrowse -noautoopen -readonly -mountpoint "${MOUNT}" >/dev/null \
    || { printf 'Could not mount %s\n' "${DMG}" >&2; MOUNT=""; exit 1; }

failures=0
check() {
    if [[ -e "${MOUNT}/$1" ]]; then
        printf '  ok      %s\n' "$1"
    else
        printf '  MISSING %s\n' "$1"
        failures=$((failures + 1))
    fi
}

printf 'Verifying %s (mounted at %s)\n' "$(basename "${DMG}")" "${MOUNT}"
check "Matrix Code.app"
check "Matrix Code.saver"
check "Applications"
check ".DS_Store"
check ".background/background.tiff"
check ".VolumeIcon.icns"

[[ -L "${MOUNT}/Applications" ]] || {
    printf '  Applications is not a symlink\n'; failures=$((failures + 1)); }

# The volume's real name, read from the filesystem rather than inferred from the
# mount path. hdiutil imageinfo does not report it for these APFS images, so ask
# diskutil about the mounted volume instead.
volume_info="${TEMP_ROOT}/volume-info.plist"
diskutil info -plist "${MOUNT}" > "${volume_info}" 2>/dev/null || true
volume_name="$(/usr/libexec/PlistBuddy -c 'Print :VolumeName' "${volume_info}" 2>/dev/null || true)"
if [[ "${volume_name}" != "Matrix Code" ]]; then
    printf '  Volume name is "%s", expected "Matrix Code" — the committed\n' "${volume_name}"
    printf '  layout is keyed to that name and will not apply.\n'
    failures=$((failures + 1))
fi

if [[ "${failures}" -eq 0 ]]; then
    printf '\nDMG structure OK\n'
else
    printf '\n%d problem(s) found\n' "${failures}" >&2
    exit 1
fi
