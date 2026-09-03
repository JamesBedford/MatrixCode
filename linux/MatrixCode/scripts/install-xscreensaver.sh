#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
binary="${project_dir}/out/build/linux-release/MatrixCode"
user_bin="${XDG_BIN_HOME:-${HOME}/.local/bin}"
user_config="${HOME}/.xscreensaver"
mkdir -p "${user_bin}"

if [[ -x /usr/libexec/xscreensaver/matrixcode ]]; then
  command_line="/usr/libexec/xscreensaver/matrixcode -root"
else
  if [[ ! -x "${binary}" ]]; then
    "${project_dir}/scripts/build.sh"
  fi
  install -m 0755 "${binary}" "${user_bin}/MatrixCode"
  install -m 0755 "${project_dir}/resources/xscreensaver/matrixcode" \
    "${user_bin}/matrixcode-xscreensaver"
  command_line="${user_bin}/matrixcode-xscreensaver -root"
fi
registration_status=missing
if [[ -f "${user_config}" ]]; then
  registration_status=$(awk -v command_line="${command_line}" '
    function continues(line) { return line ~ /\\[[:space:]]*$/ }
    function inspect(line) {
      if (index(line, command_line) > 0) exact = 1
      if (line ~ /[^[:space:]]*[Mm]atrix[Cc]ode[^[:space:]]*[[:space:]]+(--screensaver|-root)/) {
        legacy = 1
      }
    }
    /^[[:space:]]*([*]|XScreenSaver[.])?programs[[:space:]]*:/ {
      inspect($0)
      in_programs = continues($0)
      next
    }
    in_programs {
      inspect($0)
      in_programs = continues($0)
    }
    END {
      if (exact) print "exact"
      else if (legacy) print "legacy"
      else print "missing"
    }
  ' "${user_config}")
fi

if [[ "${registration_status}" == exact ]]; then
  printf 'MatrixCode is already registered in %s\n' "${user_config}"
  exit 0
fi

if [[ ! -f "${user_config}" ]]; then
  umask 077
  printf 'programs:\t%s \n' "${command_line}" > "${user_config}"
  chmod 0600 "${user_config}"
elif grep -Eq '^[[:space:]]*([*]|XScreenSaver[.])?programs[[:space:]]*:' "${user_config}"; then
  temporary_config=$(mktemp "${user_config}.XXXXXX")
  trap 'rm -f -- "${temporary_config}"' EXIT
  if [[ "${registration_status}" == legacy ]]; then
    awk -v command_line="${command_line}" '
      function continues(line) { return line ~ /\\[[:space:]]*$/ }
      /^[[:space:]]*([*]|XScreenSaver[.])?programs[[:space:]]*:/ {
        in_programs = continues($0)
        sub(/[^[:space:]]*[Mm]atrix[Cc]ode[^[:space:]]*[[:space:]]+(--screensaver|-root)/,
          command_line)
        print
        next
      }
      in_programs {
        continuation = continues($0)
        sub(/[^[:space:]]*[Mm]atrix[Cc]ode[^[:space:]]*[[:space:]]+(--screensaver|-root)/,
          command_line)
        print
        in_programs = continuation
        next
      }
      { print }
    ' "${user_config}" > "${temporary_config}"
  else
    programs_line=$(awk '
      /^[[:space:]]*([*]|XScreenSaver[.])?programs[[:space:]]*:/ { print; exit }
    ' "${user_config}")
    programs_value=${programs_line#*:}
    shift_selection=0
    if [[ -n "${programs_value//[[:space:]]/}" ]]; then shift_selection=1; fi
    awk -v command_line="${command_line}" -v shift_selection="${shift_selection}" '
      shift_selection && /^[[:space:]]*selected[[:space:]]*:[[:space:]]*[0-9]+/ {
        match($0, /[0-9]+/)
        selected = substr($0, RSTART, RLENGTH) + 1
        print substr($0, 1, RSTART - 1) selected substr($0, RSTART + RLENGTH)
        next
      }
      !inserted && /^[[:space:]]*([*]|XScreenSaver[.])?programs[[:space:]]*:/ {
        separator = index($0, ":")
        key = substr($0, 1, separator)
        value = substr($0, separator + 1)
        sub(/^[[:space:]]*/, "", value)
        if ($0 ~ /\\[[:space:]]*$/) {
          print
          printf "\t\t%s %cn%c\n", command_line, 92, 92
        } else if (length(value) > 0) {
          printf "%s\t%c\n", key, 92
          printf "\t\t%s %cn%c\n", command_line, 92, 92
          printf "\t\t%s\n", value
        } else {
          printf "%s\t%s\n", key, command_line
        }
        inserted = 1
        next
      }
      { print }
    ' "${user_config}" > "${temporary_config}"
  fi
  chmod --reference="${user_config}" "${temporary_config}"
  mv -- "${temporary_config}" "${user_config}"
  trap - EXIT
else
  printf '\nprograms:\t%s \n' "${command_line}" >> "${user_config}"
fi
printf 'Registered Matrix Code with XScreenSaver using %s.\n' "${command_line}"
