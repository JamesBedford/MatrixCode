#!/usr/bin/env bash
#
# Builds and packages the native Matrix Code app and screen saver.
#
# Usage:
#   ./scripts/build-release.sh                         # Release (default)
#   ./scripts/build-release.sh --release               # Release
#   ./scripts/build-release.sh --debug                 # Debug
#   ./scripts/build-release.sh --configuration Debug   # Debug
#
# Debug products are ad-hoc signed. Release products use Developer ID signing
# and are notarized unless --skip-notarize is supplied.
#
# One-time notarization setup:
#   xcrun notarytool store-credentials "notarytool" \
#     --key /path/to/AuthKey_XXXXXXXXXX.p8 \
#     --key-id XXXXXXXXXX \
#     --issuer <issuer-uuid>

set -euo pipefail

readonly SCHEME="MatrixCode"
readonly PROJECT_NAME="MatrixCodeScreenSaver.xcodeproj"
readonly TEAM_ID="7NBMEUUG5K"
readonly SIGN_IDENTITY="Developer ID Application: James Bedford (${TEAM_ID})"
readonly NOTARY_PROFILE="notarytool"
readonly VOLUME_NAME="Matrix Code"
readonly DMG_NAME="MatrixCode.dmg"

info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: ./scripts/build-release.sh [options]

Build and package the native Matrix Code.app and Matrix Code.saver.

Options:
  --release                    Build the Release configuration (default).
  --debug                      Build the Debug configuration.
  -c, --configuration VALUE    Build Debug or Release.
  --skip-notarize              Developer ID sign Release, but do not notarize.
  --local-signing              Ad-hoc sign for local use.
  --auto-signing               Developer ID sign if the identity is available,
                               otherwise warn and fall back to ad-hoc signing
                               (used by build.sh). Does not notarize.
  -h, --help                   Show this help.

Environment:
  DEVELOPER_DIR                Xcode developer directory to use.
  XCODE_APP                    Xcode.app path to use.

Outputs:
  macos/MatrixCodeScreenSaver/build/Debug/
  macos/MatrixCodeScreenSaver/build/Release/

Release builds also include matching dSYMs and a UUID report. The styled
MatrixCode.dmg is Developer ID signed and notarized unless --local-signing or
--skip-notarize is supplied.
USAGE
}

CONFIGURATION="Release"
configuration_was_selected=false
SKIP_NOTARIZE=false
LOCAL_SIGNING=false
# Tracks an explicit --local-signing argument, as distinct from the ad-hoc
# signing that a Debug configuration implies. Only the explicit form conflicts
# with --auto-signing.
local_signing_was_requested=false
AUTO_SIGNING=false

select_configuration() {
    local requested="$1"
    case "${requested}" in
        debug|Debug) requested="Debug" ;;
        release|Release) requested="Release" ;;
        *) fail "Configuration must be Debug or Release, not '${requested}'." ;;
    esac

    if [[ "${configuration_was_selected}" == true && "${CONFIGURATION}" != "${requested}" ]]; then
        fail "Choose only one configuration: Debug or Release."
    fi
    CONFIGURATION="${requested}"
    configuration_was_selected=true
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debug)
            select_configuration "Debug"
            ;;
        --release)
            select_configuration "Release"
            ;;
        -c|--configuration)
            [[ $# -ge 2 ]] || fail "$1 requires Debug or Release."
            select_configuration "$2"
            shift
            ;;
        --configuration=*)
            select_configuration "${1#*=}"
            ;;
        --skip-notarize)
            SKIP_NOTARIZE=true
            ;;
        --local-signing)
            LOCAL_SIGNING=true
            local_signing_was_requested=true
            ;;
        --auto-signing)
            AUTO_SIGNING=true
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "Unknown option: $1"
            ;;
    esac
    shift
done

if [[ "${CONFIGURATION}" == "Debug" ]]; then
    [[ "${SKIP_NOTARIZE}" == false ]] \
        || fail "--skip-notarize is only valid for Release builds."
    LOCAL_SIGNING=true
fi
if [[ "${LOCAL_SIGNING}" == true && "${SKIP_NOTARIZE}" == true ]]; then
    fail "Choose either --local-signing or --skip-notarize, not both."
fi

# --auto-signing prefers the real Developer ID identity and degrades to ad-hoc
# signing rather than failing the build, so a machine without the certificate can
# still produce working local products. Notarization is never attempted here: it
# needs the network and several minutes, which a routine local build should not
# pay. Use --release for a notarized distribution build.
if [[ "${AUTO_SIGNING}" == true ]]; then
    if [[ "${local_signing_was_requested}" == true || "${SKIP_NOTARIZE}" == true ]]; then
        fail "--auto-signing cannot be combined with --local-signing or --skip-notarize."
    fi
    if [[ "${CONFIGURATION}" == "Debug" ]]; then
        LOCAL_SIGNING=true
    elif security find-identity -v -p codesigning 2>/dev/null \
        | grep -qF "${SIGN_IDENTITY}"; then
        SKIP_NOTARIZE=true
        printf '\n\033[1;34m==>\033[0m Signing with %s\n' "${SIGN_IDENTITY}"
    else
        LOCAL_SIGNING=true
        printf '\n\033[1;33mWarning:\033[0m Developer ID identity not found in the Keychain:\n' >&2
        printf '  %s\n' "${SIGN_IDENTITY}" >&2
        printf 'Falling back to ad-hoc signing. These products are for local use only\n' >&2
        printf 'and will not pass Gatekeeper on another Mac.\n' >&2
    fi
fi

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly NATIVE_DIR="${REPO_ROOT}/macos/MatrixCodeScreenSaver"
readonly BUILD_ROOT="${NATIVE_DIR}/build"
readonly OUTPUT_DIR="${BUILD_ROOT}/${CONFIGURATION}"
readonly DMG_RESOURCES="${NATIVE_DIR}/Resources/DMG"
readonly LOCK_FILE="${BUILD_ROOT}/.${CONFIGURATION}.lock"

. "${REPO_ROOT}/scripts/lib/xcode-developer-dir.sh"

DEVELOPER_DIR="$(matrixcode_resolve_developer_dir)" || exit 1
export DEVELOPER_DIR
readonly DEVELOPER_DIR
readonly XCODEBUILD="${DEVELOPER_DIR}/usr/bin/xcodebuild"

for command in xcodegen codesign ditto dwarfdump find hdiutil lipo lockf otool security \
    shasum spctl unzip xattr xcrun; do
    command -v "${command}" >/dev/null 2>&1 || fail "Required command not found: ${command}"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "Required command not found: /usr/libexec/PlistBuddy"
# SetFile is only needed at DMG staging time, near the end of the build. Check it
# here so a missing one costs two seconds rather than a whole build and notarize.
readonly SETFILE="${DEVELOPER_DIR}/usr/bin/SetFile"
[[ -x "${SETFILE}" ]] || fail "Required command not found: ${SETFILE}"

if [[ "${LOCAL_SIGNING}" == false ]]; then
    identities="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    grep -qF "${SIGN_IDENTITY}" <<<"${identities}" \
        || fail "Signing identity not found in Keychain: ${SIGN_IDENTITY}"
    if [[ "${SKIP_NOTARIZE}" == false ]]; then
        xcrun notarytool history --keychain-profile "${NOTARY_PROFILE}" >/dev/null 2>&1 \
            || fail "No notarytool profile '${NOTARY_PROFILE}'. Configure it or pass --skip-notarize."
    fi
fi

xcode_version="$("${XCODEBUILD}" -version)"
info "Using ${xcode_version//$'\n'/ } at ${DEVELOPER_DIR}"

temp_parent="${TMPDIR:-/private/tmp}"
temp_parent="${temp_parent%/}"
TEMP_ROOT="$(mktemp -d "${temp_parent}/MatrixCodeBuild.XXXXXX")"
PUBLISH_DIR=""
BACKUP_DIR=""
DMG_MOUNT=""

cleanup() {
    if [[ -n "${DMG_MOUNT:-}" && -d "${DMG_MOUNT}" ]]; then
        hdiutil detach "${DMG_MOUNT}" -quiet 2>/dev/null \
            || hdiutil detach "${DMG_MOUNT}" -force -quiet 2>/dev/null || true
    fi
    [[ -z "${TEMP_ROOT:-}" || ! -d "${TEMP_ROOT}" ]] || rm -rf "${TEMP_ROOT}"
    [[ -z "${PUBLISH_DIR:-}" || ! -e "${PUBLISH_DIR}" ]] || rm -rf "${PUBLISH_DIR}"
    if [[ -n "${BACKUP_DIR:-}" && -e "${BACKUP_DIR}" ]]; then
        if [[ ! -e "${OUTPUT_DIR}" ]]; then
            mv "${BACKUP_DIR}" "${OUTPUT_DIR}" 2>/dev/null || true
        else
            rm -rf "${BACKUP_DIR}"
        fi
    fi
}
trap cleanup EXIT

mkdir -p "${BUILD_ROOT}"
exec 9>>"${LOCK_FILE}"
if ! /usr/bin/lockf -s -t 0 9; then
    lock_owner=""
    read -r lock_owner < "${LOCK_FILE}" || true
    if [[ "${lock_owner}" =~ ^[0-9]+$ ]]; then
        fail "Another ${CONFIGURATION} build is already running with PID ${lock_owner}."
    fi
    fail "Another ${CONFIGURATION} build is already running."
fi
printf '%s\n' "$$" > "${LOCK_FILE}"

readonly PROJECT_STAGE="${TEMP_ROOT}/project"
readonly DERIVED_DATA="${TEMP_ROOT}/DerivedData"
readonly PACKAGE_STAGE="${TEMP_ROOT}/package"
readonly ZIP_CHECK_STAGE="${TEMP_ROOT}/zip-check"
mkdir -p "${PROJECT_STAGE}" "${PACKAGE_STAGE}" "${ZIP_CHECK_STAGE}"

# XcodeGen writes Info.plists and the project it generates. Keep all of those
# writes in the temporary build tree so a build cannot modify the repository's
# checked-in Xcode project, shared scheme, or per-user Xcode data.
cp "${NATIVE_DIR}/project.yml" "${PROJECT_STAGE}/project.yml"
ln -s "${NATIVE_DIR}/Source" "${PROJECT_STAGE}/Source"
ln -s "${NATIVE_DIR}/AppSource" "${PROJECT_STAGE}/AppSource"
ln -s "${NATIVE_DIR}/Tests" "${PROJECT_STAGE}/Tests"
ditto "${NATIVE_DIR}/Resources" "${PROJECT_STAGE}/Resources"

info "Generating temporary Xcode project"
xcodegen generate \
    --quiet \
    --spec "${PROJECT_STAGE}/project.yml" \
    --project "${PROJECT_STAGE}" \
    --project-root "${PROJECT_STAGE}"

info "Building ${CONFIGURATION}"
"${XCODEBUILD}" build \
    -project "${PROJECT_STAGE}/${PROJECT_NAME}" \
    -scheme "${SCHEME}" \
    -configuration "${CONFIGURATION}" \
    -derivedDataPath "${DERIVED_DATA}" \
    -destination "platform=macOS,arch=arm64" \
    -quiet \
    || fail "${CONFIGURATION} build failed"

readonly PRODUCTS_DIR="${DERIVED_DATA}/Build/Products/${CONFIGURATION}"
readonly SOURCE_APP="${PRODUCTS_DIR}/Matrix Code.app"
readonly SOURCE_SAVER="${PRODUCTS_DIR}/Matrix Code.saver"
[[ -d "${SOURCE_APP}" ]] || fail "Build did not produce Matrix Code.app."
[[ -d "${SOURCE_SAVER}" ]] || fail "Build did not produce Matrix Code.saver."

ditto "${SOURCE_APP}" "${PACKAGE_STAGE}/Matrix Code.app"
ditto "${SOURCE_SAVER}" "${PACKAGE_STAGE}/Matrix Code.saver"

codesign_with_retry() {
    local description="$1"
    shift
    if codesign "$@" >/dev/null; then
        return
    fi
    info "Retrying Developer ID signing for ${description}"
    sleep 2
    codesign "$@" >/dev/null || fail "Developer ID signing failed for ${description}."
}

for product in "${PACKAGE_STAGE}/Matrix Code.app" "${PACKAGE_STAGE}/Matrix Code.saver"; do
    xattr -cr "${product}"
    touch "${product}"
    if [[ "${LOCAL_SIGNING}" == true ]]; then
        codesign --force --sign - "${product}" >/dev/null
    else
        codesign_with_retry "$(basename "${product}")" \
            --force --sign "${SIGN_IDENTITY}" \
            --timestamp --options runtime "${product}"
    fi
done

validate_product() {
    local product="$1"
    local executable="${product}/Contents/MacOS/Matrix Code"
    [[ -f "${executable}" ]] || fail "$(basename "${product}") is missing its executable."
    [[ -f "${product}/Contents/Resources/MatrixCodeShaders.msl" ]] \
        || fail "$(basename "${product}") is missing MatrixCodeShaders.msl."
    codesign --verify --deep --strict "${product}" \
        || fail "Signature verification failed for $(basename "${product}")."
    if [[ "${LOCAL_SIGNING}" == false ]]; then
        local signature_info
        signature_info="$(codesign -dvv "${product}" 2>&1 || true)"
        grep -q 'flags=.*runtime' <<<"${signature_info}" \
            || fail "Hardened runtime is missing from $(basename "${product}")."
    fi

    local architectures
    architectures="$(lipo -archs "${executable}")"
    [[ "${architectures}" == "arm64" ]] \
        || fail "$(basename "${product}") has unexpected architectures: ${architectures}"

    local dependencies
    dependencies="$(otool -L "${executable}")"
    if grep -q "WebKit" <<<"${dependencies}"; then
        fail "$(basename "${product}") unexpectedly links WebKit."
    fi

    local web_asset
    web_asset="$(find "${product}" -type f \( -name '*.html' -o -name '*.js' -o -name '*.ts' \) -print -quit)"
    [[ -z "${web_asset}" ]] \
        || fail "$(basename "${product}") unexpectedly contains web asset ${web_asset}."
}

info "Verifying native products"
validate_product "${PACKAGE_STAGE}/Matrix Code.app"
validate_product "${PACKAGE_STAGE}/Matrix Code.saver"

read_plist() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

APP_VERSION="$(read_plist "${PACKAGE_STAGE}/Matrix Code.app" CFBundleShortVersionString)"
APP_BUILD="$(read_plist "${PACKAGE_STAGE}/Matrix Code.app" CFBundleVersion)"
APP_MINIMUM_SYSTEM="$(read_plist "${PACKAGE_STAGE}/Matrix Code.app" LSMinimumSystemVersion)"
SAVER_VERSION="$(read_plist "${PACKAGE_STAGE}/Matrix Code.saver" CFBundleShortVersionString)"
SAVER_BUILD="$(read_plist "${PACKAGE_STAGE}/Matrix Code.saver" CFBundleVersion)"
SAVER_MINIMUM_SYSTEM="$(read_plist "${PACKAGE_STAGE}/Matrix Code.saver" LSMinimumSystemVersion)"
[[ "${APP_VERSION}" == "${SAVER_VERSION}" ]] || fail "App and saver versions do not match."
[[ "${APP_BUILD}" == "${SAVER_BUILD}" ]] || fail "App and saver build numbers do not match."
[[ "${APP_MINIMUM_SYSTEM}" == "${SAVER_MINIMUM_SYSTEM}" ]] \
    || fail "App and saver minimum macOS versions do not match."
readonly APP_VERSION APP_BUILD APP_MINIMUM_SYSTEM

create_zip() {
    ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$1" "$2"
}

if [[ "${LOCAL_SIGNING}" == false && "${SKIP_NOTARIZE}" == false ]]; then
    info "Notarizing Matrix Code.app"
    create_zip "${PACKAGE_STAGE}/Matrix Code.app" "${TEMP_ROOT}/Matrix Code.app.zip"
    xcrun notarytool submit "${TEMP_ROOT}/Matrix Code.app.zip" \
        --keychain-profile "${NOTARY_PROFILE}" --wait \
        || fail "Matrix Code.app notarization failed"
    xcrun stapler staple "${PACKAGE_STAGE}/Matrix Code.app" \
        || fail "Stapling Matrix Code.app failed"
    validate_product "${PACKAGE_STAGE}/Matrix Code.app"
fi

info "Packaging Matrix Code ${APP_VERSION} (${APP_BUILD})"
create_zip "${PACKAGE_STAGE}/Matrix Code.app" "${PACKAGE_STAGE}/Matrix Code.app.zip"
create_zip "${PACKAGE_STAGE}/Matrix Code.saver" "${PACKAGE_STAGE}/Matrix Code.saver.zip"
unzip -tq "${PACKAGE_STAGE}/Matrix Code.app.zip" >/dev/null
unzip -tq "${PACKAGE_STAGE}/Matrix Code.saver.zip" >/dev/null

mkdir -p "${ZIP_CHECK_STAGE}/app" "${ZIP_CHECK_STAGE}/saver"
unzip -q "${PACKAGE_STAGE}/Matrix Code.app.zip" -d "${ZIP_CHECK_STAGE}/app"
unzip -q "${PACKAGE_STAGE}/Matrix Code.saver.zip" -d "${ZIP_CHECK_STAGE}/saver"
validate_product "${ZIP_CHECK_STAGE}/app/Matrix Code.app"
validate_product "${ZIP_CHECK_STAGE}/saver/Matrix Code.saver"

checksum_files=("Matrix Code.app.zip" "Matrix Code.saver.zip")
if [[ "${CONFIGURATION}" == "Release" ]]; then
    readonly APP_DSYM="${PRODUCTS_DIR}/Matrix Code.app.dSYM"
    readonly SAVER_DSYM="${PRODUCTS_DIR}/Matrix Code.saver.dSYM"
    [[ -d "${APP_DSYM}" ]] || fail "Release build did not produce Matrix Code.app.dSYM."
    [[ -d "${SAVER_DSYM}" ]] || fail "Release build did not produce Matrix Code.saver.dSYM."

    app_binary_uuids="$(dwarfdump --uuid "${PACKAGE_STAGE}/Matrix Code.app/Contents/MacOS/Matrix Code" | awk '{print $2}' | sort)"
    app_dsym_uuids="$(dwarfdump --uuid "${APP_DSYM}" | awk '{print $2}' | sort)"
    saver_binary_uuids="$(dwarfdump --uuid "${PACKAGE_STAGE}/Matrix Code.saver/Contents/MacOS/Matrix Code" | awk '{print $2}' | sort)"
    saver_dsym_uuids="$(dwarfdump --uuid "${SAVER_DSYM}" | awk '{print $2}' | sort)"
    [[ "${app_binary_uuids}" == "${app_dsym_uuids}" ]] \
        || fail "Matrix Code.app dSYM UUIDs do not match its executable."
    [[ "${saver_binary_uuids}" == "${saver_dsym_uuids}" ]] \
        || fail "Matrix Code.saver dSYM UUIDs do not match its executable."

    mkdir -p "${TEMP_ROOT}/dSYMs"
    ditto "${APP_DSYM}" "${TEMP_ROOT}/dSYMs/Matrix Code.app.dSYM"
    ditto "${SAVER_DSYM}" "${TEMP_ROOT}/dSYMs/Matrix Code.saver.dSYM"
    create_zip "${TEMP_ROOT}/dSYMs" "${PACKAGE_STAGE}/Matrix Code-dSYMs.zip"
    {
        printf 'Matrix Code.app\n'
        dwarfdump --uuid "${PACKAGE_STAGE}/Matrix Code.app/Contents/MacOS/Matrix Code"
        printf '\nMatrix Code.saver\n'
        dwarfdump --uuid "${PACKAGE_STAGE}/Matrix Code.saver/Contents/MacOS/Matrix Code"
    } > "${PACKAGE_STAGE}/Matrix Code-UUIDs.txt"
    unzip -tq "${PACKAGE_STAGE}/Matrix Code-dSYMs.zip" >/dev/null
    mkdir -p "${ZIP_CHECK_STAGE}/dSYMs"
    unzip -q "${PACKAGE_STAGE}/Matrix Code-dSYMs.zip" -d "${ZIP_CHECK_STAGE}/dSYMs"
    extracted_app_dsym_uuids="$(dwarfdump --uuid "${ZIP_CHECK_STAGE}/dSYMs/dSYMs/Matrix Code.app.dSYM" | awk '{print $2}' | sort)"
    extracted_saver_dsym_uuids="$(dwarfdump --uuid "${ZIP_CHECK_STAGE}/dSYMs/dSYMs/Matrix Code.saver.dSYM" | awk '{print $2}' | sort)"
    [[ "${app_binary_uuids}" == "${extracted_app_dsym_uuids}" ]] \
        || fail "Archived Matrix Code.app dSYM UUIDs do not match its executable."
    [[ "${saver_binary_uuids}" == "${extracted_saver_dsym_uuids}" ]] \
        || fail "Archived Matrix Code.saver dSYM UUIDs do not match its executable."
    checksum_files+=("Matrix Code-dSYMs.zip" "Matrix Code-UUIDs.txt")
fi

readonly DMG_STAGE="${TEMP_ROOT}/dmg-stage"
readonly DMG_PATH="${PACKAGE_STAGE}/${DMG_NAME}"
mkdir -p "${DMG_STAGE}/.background"
ditto "${PACKAGE_STAGE}/Matrix Code.app" "${DMG_STAGE}/Matrix Code.app"
ditto "${PACKAGE_STAGE}/Matrix Code.saver" "${DMG_STAGE}/Matrix Code.saver"
ln -s /Applications "${DMG_STAGE}/Applications"

# Finder reads the window geometry, icon positions and background from these.
# They are generated by scripts/generate_dmg_{background,layout}.py and committed;
# a normal build only copies them in, so it needs no extra tooling.
for styling in DS_Store background.tiff VolumeIcon.icns; do
    [[ -f "${DMG_RESOURCES}/${styling}" ]] \
        || fail "Missing DMG styling resource: ${DMG_RESOURCES}/${styling}"
done
cp "${DMG_RESOURCES}/DS_Store" "${DMG_STAGE}/.DS_Store"
cp "${DMG_RESOURCES}/background.tiff" "${DMG_STAGE}/.background/background.tiff"
cp "${DMG_RESOURCES}/VolumeIcon.icns" "${DMG_STAGE}/.VolumeIcon.icns"

info "Building styled DMG"
# The custom-icon bit has to be set on the mounted volume itself: hdiutil does
# not carry it over from the staging folder, and without it Finder shows the
# generic disc icon instead of .VolumeIcon.icns. So build read/write, mount,
# flag the volume, then compress.
readonly DMG_READWRITE="${TEMP_ROOT}/MatrixCode-rw.dmg"
hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${DMG_STAGE}" \
    -ov -format UDRW -quiet "${DMG_READWRITE}" \
    || fail "DMG creation failed"

DMG_MOUNT="$(hdiutil attach "${DMG_READWRITE}" -nobrowse -noautoopen \
    | grep -o '/Volumes/.*' | head -1)"
[[ -n "${DMG_MOUNT}" ]] || fail "Could not mount the DMG to set its volume icon."
"${SETFILE}" -a C "${DMG_MOUNT}" \
    || fail "Could not set the custom-icon attribute on the DMG volume."
hdiutil detach "${DMG_MOUNT}" -quiet \
    || hdiutil detach "${DMG_MOUNT}" -force -quiet \
    || fail "Could not detach the DMG after setting its volume icon."
DMG_MOUNT=""

hdiutil convert "${DMG_READWRITE}" -format UDZO -ov -quiet -o "${DMG_PATH}" \
    || fail "DMG compression failed"

if [[ "${LOCAL_SIGNING}" == true ]]; then
    codesign --force --sign - "${DMG_PATH}" >/dev/null
else
    codesign_with_retry "${DMG_NAME}" \
        --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}"

    if [[ "${SKIP_NOTARIZE}" == false ]]; then
        info "Notarizing DMG"
        xcrun notarytool submit "${DMG_PATH}" \
            --keychain-profile "${NOTARY_PROFILE}" --wait \
            || fail "DMG notarization failed"
        xcrun stapler staple "${DMG_PATH}" || fail "Stapling DMG failed"
    fi

    codesign --verify --verbose=2 "${DMG_PATH}" \
        || fail "DMG signature verification failed"
    if [[ "${SKIP_NOTARIZE}" == false ]]; then
        assessment="$(spctl -a -vvv -t install "${DMG_PATH}" 2>&1 || true)"
        grep -q "source=Notarized Developer ID" <<<"${assessment}" \
            || fail "Gatekeeper did not accept the notarized DMG: ${assessment}"
        xcrun stapler validate "${DMG_PATH}" >/dev/null \
            || fail "DMG staple validation failed"
    fi
fi

info "Verifying DMG structure"
"${REPO_ROOT}/scripts/verify_dmg.sh" "${DMG_PATH}" || fail "DMG structure check failed"

checksum_files+=("${DMG_NAME}")

(
    cd "${PACKAGE_STAGE}"
    shasum -a 256 "${checksum_files[@]}" > SHA256SUMS.txt
)

mkdir -p "${BUILD_ROOT}"
PUBLISH_DIR="${BUILD_ROOT}/.${CONFIGURATION}.new.$$"
BACKUP_DIR="${BUILD_ROOT}/.${CONFIGURATION}.previous.$$"
rm -rf "${PUBLISH_DIR}" "${BACKUP_DIR}"
mkdir -p "${PUBLISH_DIR}"
ditto "${PACKAGE_STAGE}" "${PUBLISH_DIR}"

if [[ -e "${OUTPUT_DIR}" ]]; then
    mv "${OUTPUT_DIR}" "${BACKUP_DIR}"
fi
if mv "${PUBLISH_DIR}" "${OUTPUT_DIR}"; then
    PUBLISH_DIR=""
    rm -rf "${BACKUP_DIR}"
    BACKUP_DIR=""
else
    [[ ! -e "${BACKUP_DIR}" ]] || mv "${BACKUP_DIR}" "${OUTPUT_DIR}"
    fail "Could not publish build artifacts to ${OUTPUT_DIR}."
fi

if [[ "${CONFIGURATION}" == "Release" ]]; then
    for legacy_product in \
        "Matrix Code.app" "Matrix Code.app.zip" \
        "Matrix Code.saver" "Matrix Code.saver.zip" \
        "MatrixCode.dmg"; do
        rm -rf "${BUILD_ROOT}/${legacy_product}"
        ln -s "Release/${legacy_product}" "${BUILD_ROOT}/${legacy_product}"
    done
fi

printf '\n\033[1;32mBuild complete\033[0m\n'
printf '  Configuration  %s\n' "${CONFIGURATION}"
printf '  Version        %s (%s)\n' "${APP_VERSION}" "${APP_BUILD}"
printf '  Minimum macOS  %s\n' "${APP_MINIMUM_SYSTEM}"
printf '  Output         %s\n' "${OUTPUT_DIR}"
printf '  App zip        %s\n' "${OUTPUT_DIR}/Matrix Code.app.zip"
printf '  Saver zip      %s\n' "${OUTPUT_DIR}/Matrix Code.saver.zip"
printf '  DMG            %s\n' "${OUTPUT_DIR}/${DMG_NAME}"
if [[ "${CONFIGURATION}" == "Release" ]]; then
    printf '  dSYMs          %s\n' "${OUTPUT_DIR}/Matrix Code-dSYMs.zip"
    printf '  UUIDs          %s\n' "${OUTPUT_DIR}/Matrix Code-UUIDs.txt"
fi
printf '  SHA-256        %s\n' "${OUTPUT_DIR}/SHA256SUMS.txt"
if [[ "${LOCAL_SIGNING}" == false ]]; then
    if [[ "${SKIP_NOTARIZE}" == true ]]; then
        printf '\nRelease products are Developer ID signed but not notarized.\n'
    else
        printf '\nThe distribution DMG is Developer ID signed, notarized, and stapled.\n'
    fi
else
    printf '\nProducts are ad-hoc signed for local use and are not notarized.\n'
fi
