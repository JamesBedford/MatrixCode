#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
"${project_dir}/scripts/build.sh"
cd "${project_dir}"
cmake --build --preset linux-release --target package
