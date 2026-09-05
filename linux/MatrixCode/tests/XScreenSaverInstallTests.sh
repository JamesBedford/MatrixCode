#!/bin/sh
set -eu

installer_source=$1
launcher_source=$2
metadata_source=$3
test_directory=$(mktemp -d)

cleanup() {
  rm -rf -- "${test_directory}"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'XScreenSaver install test failed: %s\n' "$1" >&2
  exit 1
}

fake_project="${test_directory}/project"
test_home="${test_directory}/home"
user_bin="${test_directory}/bin"
mkdir -p \
  "${fake_project}/scripts" \
  "${fake_project}/resources/xscreensaver" \
  "${fake_project}/out/build/linux-release" \
  "${test_home}"
cp -- "${installer_source}" "${fake_project}/scripts/install-xscreensaver.sh"
cp -- "${launcher_source}" "${fake_project}/resources/xscreensaver/matrixcode"
cp -- "${metadata_source}" "${fake_project}/resources/xscreensaver/matrixcode.xml"
printf '%s\n' '#!/bin/sh' 'exit 0' > "${fake_project}/out/build/linux-release/MatrixCode"
chmod 0755 \
  "${fake_project}/scripts/install-xscreensaver.sh" \
  "${fake_project}/resources/xscreensaver/matrixcode" \
  "${fake_project}/out/build/linux-release/MatrixCode"

run_installer() {
  HOME="${test_home}" XDG_BIN_HOME="${user_bin}" \
    "${fake_project}/scripts/install-xscreensaver.sh"
}

expected_command="${user_bin}/matrixcode --root"
metadata_name=$(sed -n 's/.*<screensaver name="\([^"]*\)".*/\1/p' \
  "${fake_project}/resources/xscreensaver/matrixcode.xml")
[ "${metadata_name}" = "$(basename "${expected_command%% *}")" ] ||
  fail "launcher basename does not match XScreenSaver metadata"

run_installer
[ -x "${user_bin}/MatrixCode" ] || fail "application binary was not installed"
[ -x "${user_bin}/matrixcode" ] || fail "canonical launcher was not installed"
cmp -s "${fake_project}/out/build/linux-release/MatrixCode" "${user_bin}/MatrixCode" ||
  fail "installed application differs from the current build"
cmp -s "${fake_project}/resources/xscreensaver/matrixcode" "${user_bin}/matrixcode" ||
  fail "installed launcher differs from the current source"
grep -Fqx "$(printf 'programs:\t%s ' "${expected_command}")" "${test_home}/.xscreensaver" ||
  fail "fresh registration did not use the canonical launcher"

cp -- "${test_home}/.xscreensaver" "${test_directory}/first-registration"
run_installer
cmp -s "${test_directory}/first-registration" "${test_home}/.xscreensaver" ||
  fail "reinstall changed an exact registration"

printf 'mode:\t\tone\nselected:\t0\nprograms:\t%s\n' \
  '/home/example/.local/bin/matrixcode-xscreensaver --root --software' \
  > "${test_home}/.xscreensaver"
run_installer
grep -Fqx "$(printf 'programs:\t%s --software' "${expected_command}")" \
  "${test_home}/.xscreensaver" ||
  fail "legacy launcher registration was not migrated"
grep -Fq 'matrixcode-xscreensaver' "${test_home}/.xscreensaver" &&
  fail "legacy launcher name remained after migration"

printf 'mode:\t\tone\nselected:\t0\nprograms:\tmaze --root\n' \
  > "${test_home}/.xscreensaver"
run_installer
grep -Fqx "$(printf 'selected:\t1')" "${test_home}/.xscreensaver" ||
  fail "selection was not preserved when prepending a registration"
grep -Fq "${expected_command}" "${test_home}/.xscreensaver" ||
  fail "registration was not added to an existing program list"
grep -Fq 'maze --root' "${test_home}/.xscreensaver" ||
  fail "existing program was removed while registering Matrix Code"
