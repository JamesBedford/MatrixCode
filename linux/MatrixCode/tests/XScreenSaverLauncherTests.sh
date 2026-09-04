#!/bin/sh
set -u

launcher_source=$1
test_directory=$(mktemp -d)
launcher_pid=
child_pid=
grandchild_pid=

cleanup() {
  trap - EXIT HUP INT TERM
  if [ -z "${child_pid}" ] && [ -s "${test_directory}/child.pid" ]; then
    child_pid=$(sed -n '1p' "${test_directory}/child.pid")
  fi
  if [ -z "${grandchild_pid}" ] && [ -s "${test_directory}/grandchild.pid" ]; then
    grandchild_pid=$(sed -n '1p' "${test_directory}/grandchild.pid")
  fi
  if [ -n "${child_pid}" ]; then
    kill -TERM "-${child_pid}" 2>/dev/null || true
    kill -TERM "${child_pid}" 2>/dev/null || true
  fi
  if [ -n "${launcher_pid}" ]; then
    kill -TERM "${launcher_pid}" 2>/dev/null || true
    wait "${launcher_pid}" 2>/dev/null || true
  fi
  if [ -n "${child_pid}" ]; then
    kill -KILL "-${child_pid}" 2>/dev/null || true
    kill -KILL "${child_pid}" 2>/dev/null || true
  fi
  if [ -n "${grandchild_pid}" ]; then
    kill -KILL "${grandchild_pid}" 2>/dev/null || true
  fi
  rm -rf -- "${test_directory}"
}
trap cleanup EXIT HUP INT TERM

fail() {
  printf 'XScreenSaver launcher test failed: %s\n' "$1" >&2
  exit 1
}

wait_for_file() {
  path=$1
  attempts=0
  while [ ! -s "${path}" ] && [ "${attempts}" -lt 100 ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  [ -s "${path}" ] || fail "timed out waiting for ${path}"
}

wait_for_process_exit() {
  process_id=$1
  attempts=0
  while kill -0 "${process_id}" 2>/dev/null && [ "${attempts}" -lt 100 ]; do
    sleep 0.02
    attempts=$((attempts + 1))
  done
  if kill -0 "${process_id}" 2>/dev/null; then
    fail "process ${process_id} was not reaped"
  fi
}

expect_status() {
  expected=$1
  actual=$2
  description=$3
  [ "${actual}" -eq "${expected}" ] ||
    fail "${description}: expected status ${expected}, got ${actual}"
}

cp -- "${launcher_source}" "${test_directory}/matrixcode"
chmod 0755 "${test_directory}/matrixcode"

printf '%s\n' \
  '#!/bin/sh' \
  'case "${MATRIXCODE_FAKE_MODE}" in' \
  '  exit)' \
  '    exit "${MATRIXCODE_FAKE_EXIT_CODE}"' \
  '    ;;' \
  '  fallback)' \
  '    if [ "${1-}" = "--software" ]; then' \
  '      printf "%s\n" "$#" "$1" "$2" "$3" > "${MATRIXCODE_TEST_DIRECTORY}/fallback.args"' \
  '      exit 17' \
  '    fi' \
  '    exit 75' \
  '    ;;' \
  '  signal)' \
  '    trap '\''printf HUP > "${MATRIXCODE_TEST_DIRECTORY}/signal"; exit 0'\'' HUP' \
  '    trap '\''printf INT > "${MATRIXCODE_TEST_DIRECTORY}/signal"; exit 0'\'' INT' \
  '    trap '\''printf TERM > "${MATRIXCODE_TEST_DIRECTORY}/signal"; exit 0'\'' TERM' \
  '    env --default-signal=HUP,INT,TERM sleep 300 &' \
  '    printf "%s\n" "$!" > "${MATRIXCODE_TEST_DIRECTORY}/grandchild.pid"' \
  '    printf "%s\n" "$$" > "${MATRIXCODE_TEST_DIRECTORY}/child.pid"' \
  '    while :; do sleep 0.02; done' \
  '    ;;' \
  'esac' > "${test_directory}/MatrixCode"
chmod 0755 "${test_directory}/MatrixCode"

set +e
MATRIXCODE_FAKE_MODE=exit MATRIXCODE_FAKE_EXIT_CODE=23 \
  "${test_directory}/matrixcode" --root
status=$?
set -e
expect_status 23 "${status}" "ordinary child exit"

set +e
MATRIXCODE_FAKE_MODE=fallback MATRIXCODE_TEST_DIRECTORY="${test_directory}" \
  "${test_directory}/matrixcode" --root "two words"
status=$?
set -e
expect_status 17 "${status}" "software fallback exit"
[ "$(sed -n '1p' "${test_directory}/fallback.args")" = 3 ] ||
  fail "software fallback argument count changed"
[ "$(sed -n '2p' "${test_directory}/fallback.args")" = --software ] ||
  fail "software fallback flag was not prepended"
[ "$(sed -n '3p' "${test_directory}/fallback.args")" = --root ] ||
  fail "original first argument was not preserved"
[ "$(sed -n '4p' "${test_directory}/fallback.args")" = "two words" ] ||
  fail "quoted original argument was not preserved"

for signal_name in HUP INT TERM; do
  rm -f -- "${test_directory}/child.pid" "${test_directory}/grandchild.pid" \
    "${test_directory}/signal"

  env --default-signal=HUP,INT,TERM \
    MATRIXCODE_FAKE_MODE=signal MATRIXCODE_TEST_DIRECTORY="${test_directory}" \
    "${test_directory}/matrixcode" --root &
  launcher_pid=$!
  wait_for_file "${test_directory}/child.pid"
  wait_for_file "${test_directory}/grandchild.pid"
  child_pid=$(sed -n '1p' "${test_directory}/child.pid")
  grandchild_pid=$(sed -n '1p' "${test_directory}/grandchild.pid")
  child_group=$(ps -o pgid= -p "${child_pid}" | tr -d ' ')
  grandchild_group=$(ps -o pgid= -p "${grandchild_pid}" | tr -d ' ')
  [ "${child_group}" = "${child_pid}" ] ||
    fail "child ${child_pid} did not lead its own process group"
  [ "${grandchild_group}" = "${child_pid}" ] ||
    fail "grandchild ${grandchild_pid} was not in child group ${child_pid}"

  kill "-${signal_name}" "${launcher_pid}"
  set +e
  wait "${launcher_pid}"
  status=$?
  set -e
  launcher_pid=
  case "${signal_name}" in
    HUP) expected_status=129 ;;
    INT) expected_status=130 ;;
    TERM) expected_status=143 ;;
  esac
  expect_status "${expected_status}" "${status}" "${signal_name} forwarding"
  wait_for_file "${test_directory}/signal"
  [ "$(cat "${test_directory}/signal")" = "${signal_name}" ] ||
    fail "${signal_name} was not forwarded to the child"
  wait_for_process_exit "${child_pid}"
  wait_for_process_exit "${grandchild_pid}"
  child_pid=
  grandchild_pid=
done
