#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../install-tuic.sh
source "${PROJECT_ROOT}/install-tuic.sh"

assert_selected_tag() {
  local expected="$1"
  local releases="$2"
  local selected actual

  selected="$(select_latest_stable_release <<<"${releases}")"
  actual="$(jq -r '.tag_name // empty' <<<"${selected}")"
  [[ "${actual}" == "${expected}" ]] || {
    printf 'Expected stable tag %s, got %s\n' "${expected}" "${actual:-<empty>}" >&2
    return 1
  }
}

mislabelled_dev_release='[
  {"tag_name":"v2.0.0-dev3","draft":false,"prerelease":false,"assets":[]},
  {"tag_name":"v1.8.11","draft":false,"prerelease":false,"assets":[]}
]'

flagged_prerelease='[
  {"tag_name":"v2.0.0","draft":false,"prerelease":true,"assets":[]},
  {"tag_name":"tuic-server-1.0.0","draft":false,"prerelease":false,"assets":[]}
]'

assert_selected_tag "v1.8.11" "${mislabelled_dev_release}"
assert_selected_tag "tuic-server-1.0.0" "${flagged_prerelease}"

printf 'Release selection tests passed.\n'
