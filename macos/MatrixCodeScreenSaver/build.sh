#!/usr/bin/env bash
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for argument in "$@"; do
    case "${argument}" in
        -h|--help)
            cat <<'USAGE'
Usage: ./build.sh [--release|--debug|--configuration Debug|Release]

Build local, ad-hoc-signed MatrixCode.app and MatrixCode.saver packages.
Release is the default. Use ../../scripts/build-release.sh for a Developer ID
signed and notarized distribution DMG.
USAGE
            exit 0
            ;;
    esac
done

exec "${SCRIPT_DIR}/../../scripts/build-release.sh" --local-signing "$@"
