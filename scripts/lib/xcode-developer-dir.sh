# Resolves the Xcode developer directory for the native build and test scripts.
#
# Xcode is required for xcodebuild; a Command Line Tools selection is not
# sufficient. `xcode-select -p` is only one of the candidate sources, so an
# Xcode installed outside /Applications still resolves without the caller
# having to run `xcode-select --switch`.
#
# Sourced from both bash (build-release.sh) and zsh (test.sh), so it must stay
# compatible with both.
#
# Usage:
#   . "${REPO_ROOT}/scripts/lib/xcode-developer-dir.sh"
#   DEVELOPER_DIR="$(matrixcode_resolve_developer_dir)" || exit 1
#   export DEVELOPER_DIR

# Echoes the developer directory for an Xcode.app or developer-dir path,
# or returns 1 when the path has no usable xcodebuild.
matrixcode_developer_dir_for_path() {
    local candidate="$1"
    if [[ -d "${candidate}/Contents/Developer" ]]; then
        candidate="${candidate}/Contents/Developer"
    fi
    [[ -x "${candidate}/usr/bin/xcodebuild" ]] || return 1
    printf '%s\n' "${candidate}"
}

# Echoes the first usable developer directory, or returns 1 with a diagnostic
# on stderr. DEVELOPER_DIR and XCODE_APP are honoured first so callers can pin
# a specific Xcode; both are treated as errors when set but unusable, rather
# than silently falling through to a different toolchain.
matrixcode_resolve_developer_dir() {
    local candidate=""
    local app=""
    local spotlight_results=""

    if [[ -n "${DEVELOPER_DIR:-}" ]]; then
        matrixcode_developer_dir_for_path "${DEVELOPER_DIR}" && return 0
        printf 'DEVELOPER_DIR is not a valid Xcode developer directory: %s\n' \
            "${DEVELOPER_DIR}" >&2
        return 1
    fi

    if [[ -n "${XCODE_APP:-}" ]]; then
        matrixcode_developer_dir_for_path "${XCODE_APP}" && return 0
        printf 'XCODE_APP is not a valid Xcode application: %s\n' "${XCODE_APP}" >&2
        return 1
    fi

    candidate="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "${candidate}" && "${candidate}" != *CommandLineTools* ]] && \
       matrixcode_developer_dir_for_path "${candidate}"; then
        return 0
    fi

    for app in \
        "/Applications/Xcode.app" \
        "/Volumes/Data/Applications/Xcode.app" \
        "/Volumes/DATA/Applications/Xcode.app"; do
        if matrixcode_developer_dir_for_path "${app}"; then
            return 0
        fi
    done

    spotlight_results="$(mdfind "kMDItemCFBundleIdentifier == 'com.apple.dt.Xcode'" 2>/dev/null || true)"
    while IFS= read -r app; do
        [[ -n "${app}" ]] || continue
        if matrixcode_developer_dir_for_path "${app}"; then
            return 0
        fi
    done <<<"${spotlight_results}"

    printf 'Xcode not found. Install it, set XCODE_APP, or set DEVELOPER_DIR.\n' >&2
    return 1
}
