#!/bin/zsh
set -euo pipefail

SCRIPT_DIR=${0:A:h}
REPO_ROOT=${SCRIPT_DIR:h:h}
BUILD_PRODUCTS_DIR="${SCRIPT_DIR}/build/Release"
. "${REPO_ROOT}/scripts/lib/signing.sh"

matrixcode_cached_thumbnail_path() {
  local view_model_cache="$1"
  local group_index=0
  while /usr/libexec/PlistBuddy \
      -c "Print :viewModel:groups:${group_index}:items" \
      "${view_model_cache}" >/dev/null 2>&1; do
    local item_index=0
    local item_name
    while item_name="$(/usr/libexec/PlistBuddy \
        -c "Print :viewModel:groups:${group_index}:items:${item_index}:localizedName" \
        "${view_model_cache}" 2>/dev/null)"; do
      if [[ "${item_name}" == "Matrix Code" ]]; then
        local thumbnail_url
        thumbnail_url="$(/usr/libexec/PlistBuddy \
          -c "Print :viewModel:groups:${group_index}:items:${item_index}:thumbnail:image:url:relative" \
          "${view_model_cache}" 2>/dev/null)" || return 1
        [[ "${thumbnail_url}" == file://* ]] || return 1
        printf '%s\n' "${thumbnail_url#file://}"
        return 0
      fi
      item_index=$((item_index + 1))
    done
    group_index=$((group_index + 1))
  done
  return 1
}

matrixcode_thumbnail_cache_backup_directory() {
  local user_cache_root="$1"
  local backup_stamp
  backup_stamp="$(date '+%Y%m%d-%H%M%S')"
  local backup_directory="${user_cache_root}/com.matrixcode.screensaver/thumbnail-cache-backups/${backup_stamp}-$$"
  mkdir -p "${backup_directory}"
  printf '%s\n' "${backup_directory}"
}

matrixcode_invalidate_thumbnail_cache() {
  if [[ "${TMPDIR:-}" != */T/ ]]; then
    echo "Could not locate the macOS wallpaper cache; reopen System Settings if its thumbnail is stale." >&2
    return 0
  fi

  local user_cache_root="${TMPDIR%T/}C"
  if [[ "${user_cache_root}" == /var/* ]]; then
    user_cache_root="/private${user_cache_root}"
  fi
  local legacy_thumbnail_directory="${user_cache_root}/com.apple.wallpaper.extension.legacy/com.apple.wallpaper.legacy.thumbnails"
  local view_model_cache="${user_cache_root}/com.apple.wallpaper.agent/com.apple.wallpaper.view-model-cache/extension-com.apple.wallpaper.extension.legacy-screenSaver"

  local cached_thumbnail_path=""
  if [[ -f "${view_model_cache}" ]]; then
    cached_thumbnail_path="$(matrixcode_cached_thumbnail_path "${view_model_cache}")" || true
  fi
  if [[ -n "${cached_thumbnail_path}" ]]; then
    case "${cached_thumbnail_path}" in
      "${legacy_thumbnail_directory}/"*.png) ;;
      *)
        echo "Skipped unexpected Matrix Code thumbnail cache path: ${cached_thumbnail_path}" >&2
        return 0
        ;;
    esac
  elif [[ ! -d "${legacy_thumbnail_directory}" ]]; then
    return 0
  fi

  local backup_directory
  backup_directory="$(matrixcode_thumbnail_cache_backup_directory "${user_cache_root}")"
  if [[ -n "${cached_thumbnail_path}" && -f "${cached_thumbnail_path}" ]]; then
    mv "${cached_thumbnail_path}" "${backup_directory}/thumbnail.png"
  elif [[ -d "${legacy_thumbnail_directory}" ]]; then
    # Cache filenames are opaque hashes, so without a view model the complete
    # recoverable cache must be regenerated to guarantee this module is fresh.
    mv "${legacy_thumbnail_directory}" "${backup_directory}/legacy-thumbnails"
  fi
  if [[ -f "${view_model_cache}" ]]; then
    mv "${view_model_cache}" "${backup_directory}/legacy-screenSaver.plist"
  fi
  echo "Moved the stale Matrix Code thumbnail cache to ${backup_directory}."
}

OPEN_BUILD_PRODUCTS=true
for argument in "$@"; do
  case "${argument}" in
    --no-open)
      OPEN_BUILD_PRODUCTS=false
      ;;
    -h|--help)
      cat <<'USAGE'
Usage: ./install.sh [--no-open]

Build and install Matrix Code.saver, then open the Release products in Finder.

Options:
  --no-open   Do not open the build products directory in Finder.
  -h, --help  Show this help.
USAGE
      exit 0
      ;;
    *)
      echo "Unknown option: ${argument}" >&2
      echo "Usage: ./install.sh [--no-open]" >&2
      exit 2
      ;;
  esac
done

"${SCRIPT_DIR}/build.sh" --release

INSTALL_DIR="${HOME}/Library/Screen Savers"
mkdir -p "${INSTALL_DIR}"
SOURCE_SAVER="${BUILD_PRODUCTS_DIR}/Matrix Code.saver"

# Installs from before the rename are called MatrixCode.saver but carry the same
# bundle identifier, so leaving one behind lets System Settings list two entries
# and lets legacyScreenSaver keep loading the stale bundle — which makes a fresh
# install look like it did nothing.
LEGACY_SAVER="${INSTALL_DIR}/MatrixCode.saver"
if [[ -e "${LEGACY_SAVER}" ]]; then
  rm -rf "${LEGACY_SAVER}"
  echo "Removed the legacy install at ${LEGACY_SAVER}."
fi

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
  matrixcode_report_adhoc_fallback "${MATRIXCODE_SIGN_IDENTITY}" \
    "The copied saver did not verify, so its signature cannot be preserved."
  codesign --force --sign - "${INSTALL_DIR}/Matrix Code.saver"
  codesign --verify --deep --strict "${INSTALL_DIR}/Matrix Code.saver"
fi

SYSTEM_SETTINGS_WAS_RUNNING=false
if /usr/bin/pgrep -x "System Settings" >/dev/null 2>&1; then
  SYSTEM_SETTINGS_WAS_RUNNING=true
  /usr/bin/osascript -e 'tell application "System Settings" to quit' >/dev/null 2>&1 || true
  if /usr/bin/pgrep -x "System Settings" >/dev/null 2>&1; then
    /usr/bin/killall "System Settings" 2>/dev/null || true
  fi
fi

matrixcode_invalidate_thumbnail_cache
for process_name in legacyScreenSaver WallpaperLegacyExtension WallpaperAgent Wallpaper; do
  if /usr/bin/killall "${process_name}" 2>/dev/null; then
    echo "Restarted macOS's cached ${process_name} process."
  fi
done

echo "Installed Matrix Code.saver. Select it in System Settings → Screen Saver."
if [[ "${SYSTEM_SETTINGS_WAS_RUNNING}" == true ]]; then
  /usr/bin/open 'x-apple.systempreferences:com.apple.preference.desktopscreeneffect?ScreenSaver'
fi
if [[ "${OPEN_BUILD_PRODUCTS}" == true ]]; then
  /usr/bin/open "${BUILD_PRODUCTS_DIR}"
fi
