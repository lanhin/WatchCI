#!/usr/bin/env bash
# GitCode pulls adapter (GitHub-like API).
# shellcheck source=_interface.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_interface.sh"

provider_default_api_base() {
  echo "${API_BASE:-https://api.gitcode.com/api/v5}"
}

provider_auth_args() {
  local tok
  tok="$(provider_token)"
  if [[ -n "$tok" ]]; then
    echo -H "Authorization: Bearer $tok" -H "Accept: application/json"
  else
    echo -H "Accept: application/json"
  fi
}

provider_list_open_prs() {
  local base owner repo page json
  base="$(provider_default_api_base)"
  owner="${OWNER:?OWNER required}"
  repo="${REPO:?REPO required}"
  page=1
  while true; do
    # shellcheck disable=SC2046
    json="$(provider_api_get $(provider_auth_args) \
      "${base}/repos/${owner}/${repo}/pulls?state=open&per_page=100&page=${page}")" || return 1
    local count
    count="$(echo "$json" | jq 'length')"
    [[ "$count" -eq 0 ]] && break
    echo "$json" | jq -r '
      .[] | [
        (.number // .id),
        (.head.sha // .sha // ""),
        (.head.ref // .source_branch // ""),
        (.html_url // .url // "")
      ] | @tsv
    '
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
}

provider_pr_head_sha() {
  local id="$1" base owner repo
  base="$(provider_default_api_base)"
  owner="${OWNER:?}"
  repo="${REPO:?}"
  # shellcheck disable=SC2046
  provider_api_get $(provider_auth_args) \
    "${base}/repos/${owner}/${repo}/pulls/${id}" | jq -r '.head.sha // .sha'
}
