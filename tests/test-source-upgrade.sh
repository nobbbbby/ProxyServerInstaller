#!/usr/bin/env bash
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${PROJECT_ROOT}/install-tuic.sh"

# Child processes keep errexit enabled even when a failure is expected by the test.
if [[ $# -gt 0 ]]; then
  scenario="$1"
  SOURCE_URL="https://example.com/owner/tuic.git"
  SOURCE_REF="${TEST_REF:-HEAD}"
  UPGRADE_CORE_MODE=true
  TUIC_BIN="${TEST_ROOT}/tuic-server"
  TUIC_ENV="${TEST_ROOT}/settings.env"
  validate_source_options
  git() {
    if [[ "$*" == *'remote add origin'* ]]; then
      command git "${@:1:5}" "${TEST_ROOT}/repo"
    else
      command git "$@"
    fi
  }
  cargo() {
    if [[ "${scenario}" == real-build ]]; then
      command cargo "$@"
      return
    fi
    [[ "${scenario}" != build-failure ]] || return 42
    local target_dir=""
    while [[ $# -gt 0 ]]; do
      if [[ "$1" == --target-dir ]]; then target_dir="$2"; shift; fi
      shift
    done
    mkdir -p "${target_dir}/release"
    printf '#!/bin/sh\nprintf "tuic-server fixture\\n"\n' > "${target_dir}/release/tuic-server"
    chmod +x "${target_dir}/release/tuic-server"
    jq -nc --arg path "${target_dir}/release/tuic-server" \
      '{reason:"compiler-artifact",target:{name:"tuic-server"},executable:$path}'
  }
  restart_tuic_service() { touch "${TEST_ROOT}/restarted"; }
  verify_tuic_service_if_installed() { :; }
  case "$scenario" in
    fetch-failure) SOURCE_REF=missing-branch ;;
    dry-run) DRY_RUN=true ;;
  esac
  upgrade_core_from_source
  exit 0
fi

TEST_ROOT="$(mktemp -d)"
export TEST_ROOT
trap 'rm -rf -- "${TEST_ROOT}"' EXIT
command git init -q "${TEST_ROOT}/repo"
command git -C "${TEST_ROOT}/repo" config user.email test@example.com
command git -C "${TEST_ROOT}/repo" config user.name Test
printf 'fixture\n' > "${TEST_ROOT}/repo/fixture"
mkdir -p "${TEST_ROOT}/repo/src"
cat > "${TEST_ROOT}/repo/Cargo.toml" <<'MANIFEST'
[package]
name = "tuic-server"
version = "0.1.0"
edition = "2021"
MANIFEST
cat > "${TEST_ROOT}/repo/Cargo.lock" <<'LOCK'
version = 3
[[package]]
name = "tuic-server"
version = "0.1.0"
LOCK
printf 'fn main() { println!("tuic-server fixture"); }\n' > "${TEST_ROOT}/repo/src/main.rs"
command git -C "${TEST_ROOT}/repo" add .
command git -C "${TEST_ROOT}/repo" commit -qm fixture
command git -C "${TEST_ROOT}/repo" branch custom-branch
command git -C "${TEST_ROOT}/repo" tag custom-tag
expected_commit="$(command git -C "${TEST_ROOT}/repo" rev-parse HEAD)"

reset_fixture() {
  printf 'original\n' > "${TEST_ROOT}/tuic-server"
  printf 'DOMAIN=example.com\nTUIC_REPO_SAVED=owner/releases\nTUIC_SOURCE_COMMIT=old\n' > "${TEST_ROOT}/settings.env"
  rm -f "${TEST_ROOT}/restarted"
}
for ref in HEAD custom-branch custom-tag "$expected_commit"; do
  reset_fixture
  TEST_REF="$ref" bash "$0" success
  [[ -f "${TEST_ROOT}/restarted" ]]
  [[ "$("${TEST_ROOT}/tuic-server" --version)" == 'tuic-server fixture' ]]
  [[ "$(sed -n 's/^TUIC_SOURCE_COMMIT=//p' "${TEST_ROOT}/settings.env")" == "$expected_commit" ]]
  [[ "$(sed -n 's/^DOMAIN=//p' "${TEST_ROOT}/settings.env")" == example.com ]]
done
if command -v cargo >/dev/null 2>&1; then
  reset_fixture
  bash "$0" real-build
  [[ -f "${TEST_ROOT}/restarted" ]]
  [[ "$("${TEST_ROOT}/tuic-server" --version)" == 'tuic-server fixture' ]]
fi
for scenario in build-failure fetch-failure; do
  reset_fixture
  if bash "$0" "$scenario"; then
    printf 'Expected %s to fail\n' "$scenario" >&2; exit 1
  fi
  [[ "$(cat "${TEST_ROOT}/tuic-server")" == original ]]
  [[ ! -f "${TEST_ROOT}/restarted" ]]
  [[ "$(sed -n 's/^TUIC_SOURCE_COMMIT=//p' "${TEST_ROOT}/settings.env")" == old ]]
done
reset_fixture
bash "$0" dry-run
[[ "$(cat "${TEST_ROOT}/tuic-server")" == original ]]
[[ ! -f "${TEST_ROOT}/restarted" ]]
for args in '--source-ref main' '--source-url https://example.com/repo' \
  '--upgrade-core --source-url https://secret@example.com/repo' \
  '--upgrade-core --source-url file:///tmp/repo' \
  '--upgrade-core --source-url https://example.com/repo --repo owner/repo' \
  '--upgrade-core --source-ref'; do
  if bash -c 'source "$1/install-tuic.sh"; shift; parse_args "$@"; validate_source_options' _ "$PROJECT_ROOT" $args; then
    printf 'Expected invalid options to fail: %s\n' "$args" >&2; exit 1
  fi
done
# A release upgrade clears prior source provenance without changing other settings.
TUIC_ENV="${TEST_ROOT}/settings.env"
persist_core_upgrade_metadata
[[ -z "$(sed -n 's/^TUIC_SOURCE_COMMIT=//p' "$TUIC_ENV")" ]]
printf 'Source upgrade tests passed.\n'
