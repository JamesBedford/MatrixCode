#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for argument in "$@"; do
    case "${argument}" in
        -h|--help)
            cat <<'USAGE'
Usage: ./build.sh [--release|--debug|--configuration Debug|Release]

Build local Matrix Code.app and Matrix Code.saver packages plus a styled
Matrix Code disk image. Release is the default.

Products are signed with the Developer ID identity when it is present in the
Keychain. If it is not, the build warns and falls back to ad-hoc signing, which
is fine locally but will not pass Gatekeeper elsewhere.

Notarization is not performed here because it needs the network and several
minutes. Run ../../scripts/build-release.sh --release for a Developer ID signed,
notarized and stapled distribution DMG.
USAGE
            exit 0
            ;;
    esac
done

exec "${SCRIPT_DIR}/../../scripts/build-release.sh" --auto-signing "$@"
