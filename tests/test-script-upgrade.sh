#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/install-tuic.sh"

if [[ $# -gt 0 ]]; then
  scenario="$1"
  SCRIPT_PATH="${TEST_ROOT}/installer with spaces.sh"
  curl() {
    touch "${TEST_ROOT}/downloaded"
    local output=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --output ]]; then output="$2"; shift; fi
      shift
    done
    cp "${TEST_ROOT}/candidate" "${output}"
    [[ "${scenario}" != download-failure ]]
  }
  require_root() { :; }
  case "${scenario}" in
    dry-run) main --upgrade-script --dry-run ;;
    conflicting-mode) main --upgrade-script --upgrade-core ;;
    source-mode) main --upgrade-script --source-url https://example.com/repo ;;
    *) main --upgrade-script ;;
  esac
  exit 0
fi

TEST_ROOT="$(mktemp -d)"
export TEST_ROOT
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
target="${TEST_ROOT}/installer with spaces.sh"
reset_fixture() {
  rm -f -- "${target}" "${TEST_ROOT}/downloaded"
  cp "${PROJECT_ROOT}/install-tuic.sh" "${target}"
  cp "${target}" "${TEST_ROOT}/original"
  # An update must be validated without executing any of its contents.
  cat "${target}" > "${TEST_ROOT}/candidate"
  printf '\ntouch "%s/executed"\n' "${TEST_ROOT}" >> "${TEST_ROOT}/candidate"
}
assert_unchanged() {
  cmp -s "${target}" "${TEST_ROOT}/original"
  [[ -z "$(find "${TEST_ROOT}" -name '*.new.*' -print)" ]]
  [[ ! -e "${TEST_ROOT}/executed" ]]
}

reset_fixture
bash "$0" success
cmp -s "${target}" "${TEST_ROOT}/candidate"
[[ -x "${target}" && ! -e "${TEST_ROOT}/executed" ]]
[[ -z "$(find "${TEST_ROOT}" -name '*.new.*' -print)" ]]

reset_fixture
cp "${target}" "${TEST_ROOT}/candidate"
bash "$0" unchanged
assert_unchanged

for scenario in download-failure invalid-header invalid-version invalid-syntax empty conflicting-mode source-mode symlink; do
  reset_fixture
  case "${scenario}" in
    invalid-header) printf '<html>Unavailable</html>\n' > "${TEST_ROOT}/candidate" ;;
    invalid-version) printf '#!/usr/bin/env bash\necho missing-version\n' > "${TEST_ROOT}/candidate" ;;
    invalid-syntax) printf '\nif then\n' >> "${TEST_ROOT}/candidate" ;;
    empty) : > "${TEST_ROOT}/candidate" ;;
    symlink) rm "${target}"; ln -s "${TEST_ROOT}/original" "${target}" ;;
  esac
  if bash "$0" "${scenario}"; then
    printf 'Expected %s to fail\n' "${scenario}" >&2
    exit 1
  fi
  assert_unchanged
done

reset_fixture
bash "$0" dry-run
assert_unchanged
[[ ! -e "${TEST_ROOT}/downloaded" ]]
printf 'Script upgrade tests passed.\n'
