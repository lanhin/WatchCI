#!/usr/bin/env bash
# Gitee pulls adapter.
# shellcheck source=_interface.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_interface.sh"

provider_default_api_base() {
  echo "${API_BASE:-https://gitee.com/api/v5}"
}

provider_list_open_prs() {
  local base owner repo page json tok
  base="$(provider_default_api_base)"
  owner="${OWNER:?OWNER required}"
  repo="${REPO:?REPO required}"
  tok="$(provider_token)"
  page=1
  while true; do
    local url="${base}/repos/${owner}/${repo}/pulls?state=open&per_page=100&page=${page}"
    if [[ -n "$tok" ]]; then
      url="${url}&access_token=${tok}"
    fi
    json="$(curl -fsSL "$url")" || return 1
    local count
    count="$(echo "$json" | jq 'length')"
    [[ "$count" -eq 0 ]] && break
    echo "$json" | jq -r '
      .[] | [.number, .head.sha, .head.ref, (.html_url // .url // "")] | @tsv
    '
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
}

provider_pr_head_sha() {
  local id="$1" base owner repo tok url
  base="$(provider_default_api_base)"
  owner="${OWNER:?}"
  repo="${REPO:?}"
  tok="$(provider_token)"
  url="${base}/repos/${owner}/${repo}/pulls/${id}"
  [[ -n "$tok" ]] && url="${url}?access_token=${tok}"
  curl -fsSL "$url" | jq -r '.head.sha'
}
