#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
repository_dir=$(cd -- "${project_dir}/../.." && pwd)
output_dir="${project_dir}/out/arch"
prepare_only=false

usage() {
  cat <<'USAGE'
Usage: package-arch.sh [--prepare-only] [--output DIRECTORY]

Stage a checksummed local source archive and PKGBUILD, then build and test an
x86_64 Arch package with makepkg. Install build dependencies first; run as a
normal user. This command does not install the package or change desktop settings.

  --prepare-only       Generate packaging inputs without invoking makepkg
  --output DIRECTORY   Write inputs and package artifacts to this directory
  --help               Show this help
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --prepare-only) prepare_only=true; shift ;;
    --output)
      if [[ $# -lt 2 || -z "$2" || "$2" == --* ]]; then
        printf '%s\n' '--output requires a directory' >&2
        exit 2
      fi
      output_dir=$2
      shift 2
      ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown argument: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! "${prepare_only}" && ! command -v makepkg >/dev/null 2>&1; then
  printf '%s\n' 'makepkg is required to build an Arch package. Use --prepare-only to stage its inputs.' >&2
  exit 1
fi

version=$(sed -nE 's/^project\(MatrixCode VERSION ([0-9]+\.[0-9]+\.[0-9]+) LANGUAGES CXX\)$/\1/p' \
  "${project_dir}/CMakeLists.txt")
if [[ ! "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf '%s\n' 'Could not read the native MatrixCode version from CMakeLists.txt' >&2
  exit 1
fi

mkdir -p -- "${output_dir}"
output_dir=$(cd -- "${output_dir}" && pwd)
source_paths=(
  LICENSE linux/MatrixCode
  windows/MatrixCode/src/core windows/MatrixCode/include/matrixcode/core
  windows/MatrixCode/tests
)
source_excludes=(--exclude=out --exclude=.DS_Store --exclude=__pycache__ --exclude='*.pyc' --exclude=.pytest_cache)
if [[ "${output_dir}" == "${repository_dir}" || "${output_dir}" == "${repository_dir}/"* ]]; then
  for source_path in "${source_paths[@]}"; do
    if [[ "${repository_dir}/${source_path}" == "${output_dir}" ||
          "${repository_dir}/${source_path}" == "${output_dir}/"* ]]; then
      printf '%s\n' 'The output directory must not contain the native source directories' >&2
      exit 2
    fi
  done
  source_excludes+=("--exclude=${output_dir#"${repository_dir}/"}")
fi
staging_dir=$(mktemp -d)
cleanup() {
  rm -rf -- "${staging_dir}"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' HUP TERM

source_name="matrixcode-${version}"
mkdir -p -- "${staging_dir}/${source_name}"
# Preserve the relative Linux/shared-core layout without including build outputs.
# Copy the working tree so a local package includes the changes being reviewed.
COPYFILE_DISABLE=1 tar -C "${repository_dir}" \
  "${source_excludes[@]}" -cf - "${source_paths[@]}" \
  | tar -C "${staging_dir}/${source_name}" -xf -
COPYFILE_DISABLE=1 tar -C "${staging_dir}" -czf "${output_dir}/${source_name}.tar.gz" "${source_name}"

if command -v sha256sum >/dev/null 2>&1; then
  checksum=$(sha256sum "${output_dir}/${source_name}.tar.gz")
elif command -v shasum >/dev/null 2>&1; then
  checksum=$(shasum -a 256 "${output_dir}/${source_name}.tar.gz")
else
  printf '%s\n' 'sha256sum or shasum is required to checksum the source archive' >&2
  exit 1
fi
checksum=${checksum%% *}
sed -e "s/@MATRIXCODE_VERSION@/${version}/g" \
  -e "s/@MATRIXCODE_SOURCE_SHA256@/${checksum}/g" \
  "${project_dir}/packaging/arch/PKGBUILD.in" > "${output_dir}/PKGBUILD"
printf 'Arch packaging inputs: %s\n' "${output_dir}"

if ! "${prepare_only}"; then
  cd -- "${output_dir}"
  PKGDEST="${output_dir}" SRCDEST="${output_dir}" BUILDDIR="${output_dir}" \
    makepkg --cleanbuild --force --check
fi
