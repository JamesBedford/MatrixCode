# The Developer ID identity every packaging path signs with, and the report used
# when one of them cannot.
#
# Ad-hoc signed products only load on the machine that produced them: another
# Mac refuses the bundle outright, which for a screen saver shows up as an empty
# System Settings preview rather than an error. That is quiet enough to ship by
# accident, so the fallback is reported in red on stderr wherever it happens.
#
# Sourced from both bash (build-release.sh) and zsh (install.sh), so it must
# stay compatible with both.
#
# Usage:
#   . "${REPO_ROOT}/scripts/lib/signing.sh"
#   matrixcode_report_adhoc_fallback "${MATRIXCODE_SIGN_IDENTITY}" "reason line"

MATRIXCODE_TEAM_ID="7NBMEUUG5K"
MATRIXCODE_SIGN_IDENTITY="Developer ID Application: James Bedford (${MATRIXCODE_TEAM_ID})"

matrixcode_report_adhoc_fallback() {
    local identity="$1"
    local reason="$2"
    printf '\n\033[1;31mError:\033[0m %s\n' "${reason}" >&2
    printf '  Wanted: %s\n' "${identity}" >&2
    printf '\033[1;31m%s\033[0m\n' \
        'Falling back to ad-hoc signing. These products are for local use only:' >&2
    printf '\033[1;31m%s\033[0m\n' \
        'they will not load on any other Mac, and a screen saver that cannot load' >&2
    printf '\033[1;31m%s\033[0m\n' \
        'shows an empty System Settings preview. Run scripts/build-release.sh' >&2
    printf '\033[1;31m%s\033[0m\n' \
        '--release for a Developer ID signed, notarized build to share.' >&2
}
