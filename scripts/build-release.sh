#!/usr/bin/env bash
#
# Builds and packages the native MatrixCode app and screen saver.
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

info() { printf '\n\033[1;34m==>\033[0m \033[1m%s\033[0m\n' "$1"; }
fail() { printf '\n\033[1;31mError:\033[0m %s\n' "$1" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: ./scripts/build-release.sh [options]

Build and package the native MatrixCode.app and MatrixCode.saver.

Options:
  --release                    Build the Release configuration (default).
  --debug                      Build the Debug configuration.
  -c, --configuration VALUE    Build Debug or Release.
  --skip-notarize              Developer ID sign Release, but do not notarize.
  --local-signing              Ad-hoc sign without a DMG (used by build.sh).
  -h, --help                   Show this help.

Environment:
  DEVELOPER_DIR                Xcode developer directory to use.
  XCODE_APP                    Xcode.app path to use.

Outputs:
  macos/MatrixCodeScreenSaver/build/Debug/
  macos/MatrixCodeScreenSaver/build/Release/
  macos/MatrixCodeScreenSaver/dist/              (distribution Release)

Release builds also include matching dSYMs and a UUID report. By default they
are Developer ID signed and notarized as a versioned DMG in dist/.
USAGE
}

CONFIGURATION="Release"
configuration_was_selected=false
SKIP_NOTARIZE=false
LOCAL_SIGNING=false

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

readonly REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
readonly NATIVE_DIR="${REPO_ROOT}/macos/MatrixCodeScreenSaver"
readonly BUILD_ROOT="${NATIVE_DIR}/build"
readonly OUTPUT_DIR="${BUILD_ROOT}/${CONFIGURATION}"
readonly DIST_DIR="${NATIVE_DIR}/dist"
readonly LOCK_FILE="${BUILD_ROOT}/.${CONFIGURATION}.lock"

. "${REPO_ROOT}/scripts/lib/xcode-developer-dir.sh"

DEVELOPER_DIR="$(matrixcode_resolve_developer_dir)" || exit 1
export DEVELOPER_DIR
readonly DEVELOPER_DIR
readonly XCODEBUILD="${DEVELOPER_DIR}/usr/bin/xcodebuild"

for command in xcodegen codesign ditto dwarfdump find lipo lockf otool shasum unzip xattr; do
    command -v "${command}" >/dev/null 2>&1 || fail "Required command not found: ${command}"
done
[[ -x /usr/libexec/PlistBuddy ]] || fail "Required command not found: /usr/libexec/PlistBuddy"

if [[ "${LOCAL_SIGNING}" == false ]]; then
    for command in hdiutil security spctl xcrun; do
        command -v "${command}" >/dev/null 2>&1 || fail "Required command not found: ${command}"
    done
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
DIST_PUBLISH_DIR=""
DIST_BACKUP_DIR=""
DIST_OUTPUT_DIR=""

cleanup() {
    [[ -z "${TEMP_ROOT:-}" || ! -d "${TEMP_ROOT}" ]] || rm -rf "${TEMP_ROOT}"
    [[ -z "${PUBLISH_DIR:-}" || ! -e "${PUBLISH_DIR}" ]] || rm -rf "${PUBLISH_DIR}"
    if [[ -n "${BACKUP_DIR:-}" && -e "${BACKUP_DIR}" ]]; then
        if [[ ! -e "${OUTPUT_DIR}" ]]; then
            mv "${BACKUP_DIR}" "${OUTPUT_DIR}" 2>/dev/null || true
        else
            rm -rf "${BACKUP_DIR}"
        fi
    fi
    [[ -z "${DIST_PUBLISH_DIR:-}" || ! -e "${DIST_PUBLISH_DIR}" ]] \
        || rm -rf "${DIST_PUBLISH_DIR}"
    if [[ -n "${DIST_BACKUP_DIR:-}" && -e "${DIST_BACKUP_DIR}" ]]; then
        if [[ -n "${DIST_OUTPUT_DIR:-}" && ! -e "${DIST_OUTPUT_DIR}" ]]; then
            mv "${DIST_BACKUP_DIR}" "${DIST_OUTPUT_DIR}" 2>/dev/null || true
        else
            rm -rf "${DIST_BACKUP_DIR}"
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
readonly DIST_STAGE="${TEMP_ROOT}/dist"
mkdir -p "${PROJECT_STAGE}" "${PACKAGE_STAGE}" "${ZIP_CHECK_STAGE}" "${DIST_STAGE}"

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
readonly SOURCE_APP="${PRODUCTS_DIR}/MatrixCode.app"
readonly SOURCE_SAVER="${PRODUCTS_DIR}/MatrixCode.saver"
[[ -d "${SOURCE_APP}" ]] || fail "Build did not produce MatrixCode.app."
[[ -d "${SOURCE_SAVER}" ]] || fail "Build did not produce MatrixCode.saver."

ditto "${SOURCE_APP}" "${PACKAGE_STAGE}/MatrixCode.app"
ditto "${SOURCE_SAVER}" "${PACKAGE_STAGE}/MatrixCode.saver"

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

for product in "${PACKAGE_STAGE}/MatrixCode.app" "${PACKAGE_STAGE}/MatrixCode.saver"; do
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
    local executable="${product}/Contents/MacOS/MatrixCode"
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
validate_product "${PACKAGE_STAGE}/MatrixCode.app"
validate_product "${PACKAGE_STAGE}/MatrixCode.saver"

read_plist() {
    /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

APP_VERSION="$(read_plist "${PACKAGE_STAGE}/MatrixCode.app" CFBundleShortVersionString)"
APP_BUILD="$(read_plist "${PACKAGE_STAGE}/MatrixCode.app" CFBundleVersion)"
APP_MINIMUM_SYSTEM="$(read_plist "${PACKAGE_STAGE}/MatrixCode.app" LSMinimumSystemVersion)"
SAVER_VERSION="$(read_plist "${PACKAGE_STAGE}/MatrixCode.saver" CFBundleShortVersionString)"
SAVER_BUILD="$(read_plist "${PACKAGE_STAGE}/MatrixCode.saver" CFBundleVersion)"
SAVER_MINIMUM_SYSTEM="$(read_plist "${PACKAGE_STAGE}/MatrixCode.saver" LSMinimumSystemVersion)"
[[ "${APP_VERSION}" == "${SAVER_VERSION}" ]] || fail "App and saver versions do not match."
[[ "${APP_BUILD}" == "${SAVER_BUILD}" ]] || fail "App and saver build numbers do not match."
[[ "${APP_MINIMUM_SYSTEM}" == "${SAVER_MINIMUM_SYSTEM}" ]] \
    || fail "App and saver minimum macOS versions do not match."
readonly APP_VERSION APP_BUILD APP_MINIMUM_SYSTEM

create_zip() {
    ditto -c -k --keepParent --norsrc --noextattr --noqtn --noacl "$1" "$2"
}

if [[ "${LOCAL_SIGNING}" == false && "${SKIP_NOTARIZE}" == false ]]; then
    info "Notarizing MatrixCode.app"
    create_zip "${PACKAGE_STAGE}/MatrixCode.app" "${TEMP_ROOT}/MatrixCode.app.zip"
    xcrun notarytool submit "${TEMP_ROOT}/MatrixCode.app.zip" \
        --keychain-profile "${NOTARY_PROFILE}" --wait \
        || fail "MatrixCode.app notarization failed"
    xcrun stapler staple "${PACKAGE_STAGE}/MatrixCode.app" \
        || fail "Stapling MatrixCode.app failed"
    validate_product "${PACKAGE_STAGE}/MatrixCode.app"
fi

info "Packaging MatrixCode ${APP_VERSION} (${APP_BUILD})"
create_zip "${PACKAGE_STAGE}/MatrixCode.app" "${PACKAGE_STAGE}/MatrixCode.app.zip"
create_zip "${PACKAGE_STAGE}/MatrixCode.saver" "${PACKAGE_STAGE}/MatrixCode.saver.zip"
unzip -tq "${PACKAGE_STAGE}/MatrixCode.app.zip" >/dev/null
unzip -tq "${PACKAGE_STAGE}/MatrixCode.saver.zip" >/dev/null

mkdir -p "${ZIP_CHECK_STAGE}/app" "${ZIP_CHECK_STAGE}/saver"
unzip -q "${PACKAGE_STAGE}/MatrixCode.app.zip" -d "${ZIP_CHECK_STAGE}/app"
unzip -q "${PACKAGE_STAGE}/MatrixCode.saver.zip" -d "${ZIP_CHECK_STAGE}/saver"
validate_product "${ZIP_CHECK_STAGE}/app/MatrixCode.app"
validate_product "${ZIP_CHECK_STAGE}/saver/MatrixCode.saver"

checksum_files=("MatrixCode.app.zip" "MatrixCode.saver.zip")
if [[ "${CONFIGURATION}" == "Release" ]]; then
    readonly APP_DSYM="${PRODUCTS_DIR}/MatrixCode.app.dSYM"
    readonly SAVER_DSYM="${PRODUCTS_DIR}/MatrixCode.saver.dSYM"
    [[ -d "${APP_DSYM}" ]] || fail "Release build did not produce MatrixCode.app.dSYM."
    [[ -d "${SAVER_DSYM}" ]] || fail "Release build did not produce MatrixCode.saver.dSYM."

    app_binary_uuids="$(dwarfdump --uuid "${PACKAGE_STAGE}/MatrixCode.app/Contents/MacOS/MatrixCode" | awk '{print $2}' | sort)"
    app_dsym_uuids="$(dwarfdump --uuid "${APP_DSYM}" | awk '{print $2}' | sort)"
    saver_binary_uuids="$(dwarfdump --uuid "${PACKAGE_STAGE}/MatrixCode.saver/Contents/MacOS/MatrixCode" | awk '{print $2}' | sort)"
    saver_dsym_uuids="$(dwarfdump --uuid "${SAVER_DSYM}" | awk '{print $2}' | sort)"
    [[ "${app_binary_uuids}" == "${app_dsym_uuids}" ]] \
        || fail "MatrixCode.app dSYM UUIDs do not match its executable."
    [[ "${saver_binary_uuids}" == "${saver_dsym_uuids}" ]] \
        || fail "MatrixCode.saver dSYM UUIDs do not match its executable."

    mkdir -p "${TEMP_ROOT}/dSYMs"
    ditto "${APP_DSYM}" "${TEMP_ROOT}/dSYMs/MatrixCode.app.dSYM"
    ditto "${SAVER_DSYM}" "${TEMP_ROOT}/dSYMs/MatrixCode.saver.dSYM"
    create_zip "${TEMP_ROOT}/dSYMs" "${PACKAGE_STAGE}/MatrixCode-dSYMs.zip"
    {
        printf 'MatrixCode.app\n'
        dwarfdump --uuid "${PACKAGE_STAGE}/MatrixCode.app/Contents/MacOS/MatrixCode"
        printf '\nMatrixCode.saver\n'
        dwarfdump --uuid "${PACKAGE_STAGE}/MatrixCode.saver/Contents/MacOS/MatrixCode"
    } > "${PACKAGE_STAGE}/MatrixCode-UUIDs.txt"
    unzip -tq "${PACKAGE_STAGE}/MatrixCode-dSYMs.zip" >/dev/null
    mkdir -p "${ZIP_CHECK_STAGE}/dSYMs"
    unzip -q "${PACKAGE_STAGE}/MatrixCode-dSYMs.zip" -d "${ZIP_CHECK_STAGE}/dSYMs"
    extracted_app_dsym_uuids="$(dwarfdump --uuid "${ZIP_CHECK_STAGE}/dSYMs/dSYMs/MatrixCode.app.dSYM" | awk '{print $2}' | sort)"
    extracted_saver_dsym_uuids="$(dwarfdump --uuid "${ZIP_CHECK_STAGE}/dSYMs/dSYMs/MatrixCode.saver.dSYM" | awk '{print $2}' | sort)"
    [[ "${app_binary_uuids}" == "${extracted_app_dsym_uuids}" ]] \
        || fail "Archived MatrixCode.app dSYM UUIDs do not match its executable."
    [[ "${saver_binary_uuids}" == "${extracted_saver_dsym_uuids}" ]] \
        || fail "Archived MatrixCode.saver dSYM UUIDs do not match its executable."
    checksum_files+=("MatrixCode-dSYMs.zip" "MatrixCode-UUIDs.txt")
fi

if [[ "${LOCAL_SIGNING}" == false ]]; then
    readonly RELEASE_BASENAME="MatrixCode-${APP_VERSION}"
    readonly DMG_STAGE="${TEMP_ROOT}/dmg-stage"
    readonly DMG_PATH="${DIST_STAGE}/${RELEASE_BASENAME}.dmg"
    mkdir -p "${DMG_STAGE}"
    ditto "${PACKAGE_STAGE}/MatrixCode.app" "${DMG_STAGE}/MatrixCode.app"
    ditto "${PACKAGE_STAGE}/MatrixCode.saver" "${DMG_STAGE}/MatrixCode.saver"
    ln -s /Applications "${DMG_STAGE}/Applications"

    info "Building signed distribution DMG"
    hdiutil create -volname "${VOLUME_NAME}" -srcfolder "${DMG_STAGE}" \
        -ov -format UDZO -quiet "${DMG_PATH}" \
        || fail "DMG creation failed"
    codesign_with_retry "${RELEASE_BASENAME}.dmg" \
        --force --sign "${SIGN_IDENTITY}" --timestamp "${DMG_PATH}"

    if [[ "${SKIP_NOTARIZE}" == false ]]; then
        info "Notarizing distribution DMG"
        xcrun notarytool submit "${DMG_PATH}" \
            --keychain-profile "${NOTARY_PROFILE}" --wait \
            || fail "DMG notarization failed"
        xcrun stapler staple "${DMG_PATH}" || fail "Stapling DMG failed"
    fi

    codesign --verify --verbose=2 "${DMG_PATH}" || fail "DMG signature verification failed"
    if [[ "${SKIP_NOTARIZE}" == false ]]; then
        assessment="$(spctl -a -vvv -t install "${DMG_PATH}" 2>&1 || true)"
        grep -q "source=Notarized Developer ID" <<<"${assessment}" \
            || fail "Gatekeeper did not accept the notarized DMG: ${assessment}"
        xcrun stapler validate "${DMG_PATH}" >/dev/null \
            || fail "DMG staple validation failed"
    fi

    ditto "${PACKAGE_STAGE}/MatrixCode-dSYMs.zip" \
        "${DIST_STAGE}/${RELEASE_BASENAME}-dSYMs.zip"
    ditto "${PACKAGE_STAGE}/MatrixCode-UUIDs.txt" \
        "${DIST_STAGE}/${RELEASE_BASENAME}-UUIDs.txt"
    (
        cd "${DIST_STAGE}"
        shasum -a 256 \
            "${RELEASE_BASENAME}.dmg" \
            "${RELEASE_BASENAME}-dSYMs.zip" \
            "${RELEASE_BASENAME}-UUIDs.txt" \
            > "${RELEASE_BASENAME}-SHA256SUMS.txt"
    )
fi

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
        MatrixCode.app MatrixCode.app.zip MatrixCode.saver MatrixCode.saver.zip; do
        rm -rf "${BUILD_ROOT}/${legacy_product}"
        ln -s "Release/${legacy_product}" "${BUILD_ROOT}/${legacy_product}"
    done
fi

if [[ "${LOCAL_SIGNING}" == false ]]; then
    mkdir -p "${DIST_DIR}"
    DIST_OUTPUT_DIR="${DIST_DIR}/${RELEASE_BASENAME}"
    DIST_PUBLISH_DIR="${DIST_DIR}/.${RELEASE_BASENAME}.new.$$"
    DIST_BACKUP_DIR="${DIST_DIR}/.${RELEASE_BASENAME}.previous.$$"
    rm -rf "${DIST_PUBLISH_DIR}" "${DIST_BACKUP_DIR}"
    mkdir -p "${DIST_PUBLISH_DIR}"
    ditto "${DIST_STAGE}" "${DIST_PUBLISH_DIR}"
    codesign --verify --verbose=2 "${DIST_PUBLISH_DIR}/${RELEASE_BASENAME}.dmg" \
        || fail "Published DMG signature verification failed"
    (
        cd "${DIST_PUBLISH_DIR}"
        shasum -a 256 -c "${RELEASE_BASENAME}-SHA256SUMS.txt" >/dev/null
    ) || fail "Published distribution checksums failed"
    if [[ "${SKIP_NOTARIZE}" == false ]]; then
        xcrun stapler validate "${DIST_PUBLISH_DIR}/${RELEASE_BASENAME}.dmg" >/dev/null \
            || fail "Published DMG staple validation failed"
    fi

    if [[ -e "${DIST_OUTPUT_DIR}" ]]; then
        mv "${DIST_OUTPUT_DIR}" "${DIST_BACKUP_DIR}"
    fi
    if mv "${DIST_PUBLISH_DIR}" "${DIST_OUTPUT_DIR}"; then
        DIST_PUBLISH_DIR=""
        rm -rf "${DIST_BACKUP_DIR}"
        DIST_BACKUP_DIR=""
    else
        [[ ! -e "${DIST_BACKUP_DIR}" ]] \
            || mv "${DIST_BACKUP_DIR}" "${DIST_OUTPUT_DIR}"
        fail "Could not publish distribution artifacts to ${DIST_OUTPUT_DIR}."
    fi
fi

printf '\n\033[1;32mBuild complete\033[0m\n'
printf '  Configuration  %s\n' "${CONFIGURATION}"
printf '  Version        %s (%s)\n' "${APP_VERSION}" "${APP_BUILD}"
printf '  Minimum macOS  %s\n' "${APP_MINIMUM_SYSTEM}"
printf '  Output         %s\n' "${OUTPUT_DIR}"
printf '  App zip        %s\n' "${OUTPUT_DIR}/MatrixCode.app.zip"
printf '  Saver zip      %s\n' "${OUTPUT_DIR}/MatrixCode.saver.zip"
if [[ "${CONFIGURATION}" == "Release" ]]; then
    printf '  dSYMs          %s\n' "${OUTPUT_DIR}/MatrixCode-dSYMs.zip"
    printf '  UUIDs          %s\n' "${OUTPUT_DIR}/MatrixCode-UUIDs.txt"
fi
printf '  SHA-256        %s\n' "${OUTPUT_DIR}/SHA256SUMS.txt"
if [[ "${LOCAL_SIGNING}" == false ]]; then
    printf '  Distribution   %s\n' "${DIST_OUTPUT_DIR}"
    printf '  DMG            %s\n' "${DIST_OUTPUT_DIR}/${RELEASE_BASENAME}.dmg"
    printf '  Release SHA-256 %s\n' "${DIST_OUTPUT_DIR}/${RELEASE_BASENAME}-SHA256SUMS.txt"
    if [[ "${SKIP_NOTARIZE}" == true ]]; then
        printf '\nRelease products are Developer ID signed but not notarized.\n'
    else
        printf '\nThe distribution DMG is Developer ID signed, notarized, and stapled.\n'
    fi
else
    printf '\nProducts are ad-hoc signed for local use and are not notarized.\n'
fi
