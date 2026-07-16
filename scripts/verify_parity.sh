#!/bin/zsh
set -euo pipefail

ROOT_DIR=${0:A:h:h}

cd "${ROOT_DIR}"
npm test
npm run build

cd "${ROOT_DIR}/macos/MatrixCodeScreenSaver"
./test.sh
./build.sh
