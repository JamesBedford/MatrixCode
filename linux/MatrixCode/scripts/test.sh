#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "${project_dir}"
cmake --preset linux-debug
cmake --build --preset linux-debug --parallel
ctest --preset linux-debug
