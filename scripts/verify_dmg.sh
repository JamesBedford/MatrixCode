#!/usr/bin/env bash
#
# Structural check of a built MatrixCode DMG. Mounts it, asserts it carries both
# products and the styling files, then detaches.
#
# Usage: ./scripts/verify_dmg.sh path/to/MatrixCode.dmg

set -euo pipefail

DMG="${1:?Usage: verify_dmg.sh <path-to-dmg>}"
[[ -f "${DMG}" ]] || { printf 'No such DMG: %s\n' "${DMG}" >&2; exit 1; }

MOUNT=""
cleanup() {
    if [[ -n "${MOUNT}" && -d "${MOUNT}" ]]; then
        hdiutil detach "${MOUNT}" -quiet 2>/dev/null \
            || hdiutil detach "${MOUNT}" -force -quiet 2>/dev/null || true
    fi
}
trap cleanup EXIT

MOUNT="$(hdiutil attach "${DMG}" -nobrowse -noautoopen -readonly \
    | grep -o '/Volumes/.*' | head -1)"
[[ -n "${MOUNT}" ]] || { printf 'Could not mount %s\n' "${DMG}" >&2; exit 1; }

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

volume_name="$(basename "${MOUNT}")"
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
