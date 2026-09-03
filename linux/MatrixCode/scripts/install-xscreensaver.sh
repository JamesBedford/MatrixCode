#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
binary="${project_dir}/out/build/linux-release/MatrixCode"
if [[ ! -x "${binary}" ]]; then
  "${project_dir}/scripts/build.sh"
fi

user_bin="${XDG_BIN_HOME:-${HOME}/.local/bin}"
user_config="${HOME}/.xscreensaver"
mkdir -p "${user_bin}"
install -m 0755 "${binary}" "${user_bin}/matrixcode"

command_line="${user_bin}/matrixcode -root"
if [[ -f "${user_config}" ]] && grep -Fq "${command_line}" "${user_config}"; then
  printf 'MatrixCode is already registered in %s\n' "${user_config}"
  exit 0
fi

if [[ ! -f "${user_config}" ]]; then
  printf 'programs:\t%s \n' "${command_line}" > "${user_config}"
elif grep -Eq '^[[:space:]]*([*]|XScreenSaver[.])?programs[[:space:]]*:' "${user_config}"; then
  temporary_config=$(mktemp "${user_config}.XXXXXX")
  trap 'rm -f -- "${temporary_config}"' EXIT
  awk -v command_line="${command_line}" '
    !inserted && /^[[:space:]]*([*]|XScreenSaver[.])?programs[[:space:]]*:/ {
      print
      printf "\t\t%s \\n\\\n", command_line
      inserted = 1
      next
    }
    { print }
  ' "${user_config}" > "${temporary_config}"
  chmod --reference="${user_config}" "${temporary_config}"
  mv -- "${temporary_config}" "${user_config}"
  trap - EXIT
else
  printf '\nprograms:\t%s \n' "${command_line}" >> "${user_config}"
fi
printf 'Installed %s and registered it with XScreenSaver.\n' "${user_bin}/matrixcode"
