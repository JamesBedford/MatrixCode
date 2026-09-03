#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
"${project_dir}/scripts/test.sh"
"${project_dir}/scripts/build.sh"

if command -v appstreamcli >/dev/null 2>&1; then
  appstreamcli validate --no-net "${project_dir}/resources/io.github.matrixcode.MatrixCode.metainfo.xml"
fi
