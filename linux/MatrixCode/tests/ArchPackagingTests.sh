#!/usr/bin/env bash
set -euo pipefail

repository_dir=${1:?Repository root argument is required}
test_dir=$(mktemp -d)
trap 'rm -rf -- "${test_dir}"' EXIT

fail() {
  printf 'Arch packaging test failed: %s\n' "$1" >&2
  exit 1
}

fixture_dir="${test_dir}/source tree"
fixture_project="${fixture_dir}/linux/MatrixCode"
mkdir -p \
  "${fixture_project}/scripts" \
  "${fixture_project}/packaging/arch" \
  "${fixture_project}/resources" \
  "${fixture_project}/scripts/__pycache__" \
  "${fixture_project}/.pytest_cache" \
  "${fixture_project}/out/build/linux-release" \
  "${fixture_dir}/windows/MatrixCode/src/core" \
  "${fixture_dir}/windows/MatrixCode/include/matrixcode/core" \
  "${fixture_dir}/windows/MatrixCode/tests" \
  "${fixture_dir}/node_modules" \
  "${fixture_dir}/.git"
cp "${repository_dir}/linux/MatrixCode/scripts/package-arch.sh" "${fixture_project}/scripts/"
cp "${repository_dir}/linux/MatrixCode/packaging/arch/PKGBUILD.in" "${fixture_project}/packaging/arch/"
printf '%s\n' 'project(MatrixCode VERSION 2.3.4 LANGUAGES CXX)' > "${fixture_project}/CMakeLists.txt"
printf '%s\n' 'local MatrixCode license' > "${fixture_dir}/LICENSE"
printf '%s\n' 'updated working tree content' > "${fixture_project}/resources/local-change"
printf '%s\n' 'portable rain' > "${fixture_dir}/windows/MatrixCode/src/core/RainSimulation.cpp"
printf '%s\n' 'portable header' > "${fixture_dir}/windows/MatrixCode/include/matrixcode/core/RainSimulation.h"
printf '%s\n' 'portable tests' > "${fixture_dir}/windows/MatrixCode/tests/RainSimulationTests.cpp"
printf '%s\n' 'excluded native output' > "${fixture_project}/out/build/linux-release/MatrixCode"
printf '%s\n' 'excluded bytecode' > "${fixture_project}/scripts/__pycache__/installer.pyc"
printf '%s\n' 'excluded loose bytecode' > "${fixture_project}/scripts/loose.pyc"
printf '%s\n' 'excluded pytest data' > "${fixture_project}/.pytest_cache/nodeids"
printf '%s\n' 'excluded dependency' > "${fixture_dir}/node_modules/package"
printf '%s\n' 'excluded git data' > "${fixture_dir}/.git/index"

output_dir="${test_dir}/arch inputs"
bash "${fixture_project}/scripts/package-arch.sh" --prepare-only --output "${output_dir}"
[[ -f "${output_dir}/PKGBUILD" ]] || fail 'PKGBUILD was not generated'
[[ -f "${output_dir}/matrixcode-2.3.4.tar.gz" ]] || fail 'archive version was not read from CMake'
archive_listing=$(tar -tzf "${output_dir}/matrixcode-2.3.4.tar.gz")
for source_file in \
  LICENSE \
  linux/MatrixCode/CMakeLists.txt \
  linux/MatrixCode/resources/local-change \
  windows/MatrixCode/src/core/RainSimulation.cpp \
  windows/MatrixCode/include/matrixcode/core/RainSimulation.h \
  windows/MatrixCode/tests/RainSimulationTests.cpp; do
  printf '%s\n' "${archive_listing}" | grep -Fqx "matrixcode-2.3.4/${source_file}" ||
    fail "archive is missing ${source_file}"
done
if printf '%s\n' "${archive_listing}" | grep -Eq '/(out|node_modules|\.git|__pycache__|\.pytest_cache)/|\.pyc$'; then
  fail 'archive contains build output, caches, bytecode, npm dependencies, or git data'
fi
if grep -Eq '@MATRIXCODE_|SKIP' "${output_dir}/PKGBUILD"; then
  fail 'generated recipe contains an unresolved template value or skips integrity checks'
fi
# Use makepkg's recipe variables without invoking external build tooling.
source "${output_dir}/PKGBUILD"
[[ "${arch[*]}" == x86_64 ]] || fail 'current Omarchy architecture must be explicit'
[[ "${depends[*]}" == *'qt6-base>=6.10'* ]] || fail 'Qt must provide the current Arch Wayland client plugin'
[[ "${depends[*]}" != *qt6-wayland* ]] || fail 'Qt Wayland compositor package is not a client requirement'
[[ "${makedepends[*]}" == *python* ]] || fail 'native test configuration dependency is missing'
if command -v sha256sum >/dev/null 2>&1; then
  checksum=$(sha256sum "${output_dir}/matrixcode-2.3.4.tar.gz")
else
  checksum=$(shasum -a 256 "${output_dir}/matrixcode-2.3.4.tar.gz")
fi
[[ "${sha256sums[0]}" == "${checksum%% *}" ]] || fail 'source checksum does not match the staged archive'

mock_bin="${test_dir}/bin"
mkdir -p "${mock_bin}"
cat > "${mock_bin}/cmake" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'cmake\n' >> "${MATRIXCODE_PACKAGE_TEST_LOG}"
printf '%s\n' "$@" >> "${MATRIXCODE_PACKAGE_TEST_LOG}"
if [[ "$1" == --build && "${MATRIXCODE_PACKAGE_TEST_FAIL_BUILD:-0}" == 1 ]]; then
  exit 41
fi
if [[ "$1" == --install ]]; then
  [[ -n "${DESTDIR:-}" ]] || exit 42
  printf 'DESTDIR=%s\n' "${DESTDIR}" >> "${MATRIXCODE_PACKAGE_TEST_LOG}"
  mkdir -p "${DESTDIR}/usr/bin" "${DESTDIR}/usr/share/doc/matrixcode"
  printf '#!/bin/sh\nexit 0\n' > "${DESTDIR}/usr/bin/MatrixCode"
  chmod 0755 "${DESTDIR}/usr/bin/MatrixCode"
  cp "${srcdir}/matrixcode-${pkgver}/LICENSE" "${DESTDIR}/usr/share/doc/matrixcode/LICENSE"
fi
MOCK
cat > "${mock_bin}/ctest" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'ctest\nQT_QPA_PLATFORM=%s\n' "${QT_QPA_PLATFORM:-}" >> "${MATRIXCODE_PACKAGE_TEST_LOG}"
printf '%s\n' "$@" >> "${MATRIXCODE_PACKAGE_TEST_LOG}"
[[ "${MATRIXCODE_PACKAGE_TEST_FAIL_CHECK:-0}" != 1 ]] || exit 43
MOCK
cat > "${mock_bin}/makepkg" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf 'makepkg\n' >> "${MATRIXCODE_PACKAGE_TEST_LOG}"
printf '%s\n' "$@" >> "${MATRIXCODE_PACKAGE_TEST_LOG}"
[[ "${PKGDEST}" == "${PWD}" && "${SRCDEST}" == "${PWD}" && "${BUILDDIR}" == "${PWD}" ]]
source PKGBUILD
export srcdir="${PWD}/src" pkgdir="${PWD}/pkg/${pkgname}" pkgver
mkdir -p "${srcdir}" "${pkgdir}"
tar -xzf "${source[0]}" -C "${srcdir}"
build
check
package
MOCK
chmod 0755 "${mock_bin}/cmake" "${mock_bin}/ctest" "${mock_bin}/makepkg"
export MATRIXCODE_PACKAGE_TEST_LOG="${test_dir}/calls"
PATH="${mock_bin}:${PATH}" bash "${fixture_project}/scripts/package-arch.sh" --output "${output_dir}"
for required_argument in \
  '--cleanbuild' '--force' '--check' '-G' Ninja '-DCMAKE_BUILD_TYPE=None' \
  '-DCMAKE_INSTALL_PREFIX=/usr' '-DCMAKE_INSTALL_LIBDIR=lib' '-DBUILD_TESTING=ON' \
  '--output-on-failure' 'QT_QPA_PLATFORM=offscreen'; do
  grep -Fqx -- "${required_argument}" "${MATRIXCODE_PACKAGE_TEST_LOG}" ||
    fail "missing build/check argument ${required_argument}"
done
[[ -x "${output_dir}/pkg/matrixcode/usr/bin/MatrixCode" ]] || fail 'install did not stage the app'
cmp "${fixture_dir}/LICENSE" "${output_dir}/pkg/matrixcode/usr/share/licenses/matrixcode/LICENSE" ||
  fail 'MIT license is missing from the Arch license directory'
cmp "${fixture_dir}/LICENSE" "${output_dir}/pkg/matrixcode/usr/share/doc/matrixcode/LICENSE" ||
  fail 'CMake install did not stage documentation'

export MATRIXCODE_PACKAGE_TEST_FAIL_BUILD=1
if PATH="${mock_bin}:${PATH}" bash "${fixture_project}/scripts/package-arch.sh" --output "${output_dir}"; then
  fail 'package command ignored a native build failure'
fi
unset MATRIXCODE_PACKAGE_TEST_FAIL_BUILD
export MATRIXCODE_PACKAGE_TEST_FAIL_CHECK=1
if PATH="${mock_bin}:${PATH}" bash "${fixture_project}/scripts/package-arch.sh" --output "${output_dir}"; then
  fail 'package command ignored a native test failure'
fi
unset MATRIXCODE_PACKAGE_TEST_FAIL_CHECK

for invalid_argument in '--unknown' '--output'; do
  if bash "${fixture_project}/scripts/package-arch.sh" "${invalid_argument}" > /dev/null 2>&1; then
    fail "invalid argument ${invalid_argument} was accepted"
  fi
done

nested_output="${fixture_project}/local packages"
bash "${fixture_project}/scripts/package-arch.sh" --prepare-only --output "${nested_output}"
bash "${fixture_project}/scripts/package-arch.sh" --prepare-only --output "${nested_output}"
if tar -tzf "${nested_output}/matrixcode-2.3.4.tar.gz" | grep -F '/local packages/'; then
  fail 'source archive recursively includes a custom output directory'
fi
if bash "${fixture_project}/scripts/package-arch.sh" --prepare-only --output "${fixture_project}" > /dev/null 2>&1; then
  fail 'output path containing native sources was accepted'
fi
printf '%s\n' 'Arch packaging tests passed'
