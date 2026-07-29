#!/usr/bin/env bash
# GitHub pulls adapter.
# shellcheck source=_interface.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_interface.sh"

provider_default_api_base() {
  echo "${API_BASE:-https://api.github.com}"
}

provider_auth_args() {
  local tok
  tok="$(provider_token)"
  if [[ -n "$tok" ]]; then
    echo -H "Authorization: Bearer $tok" -H "Accept: application/vnd.github+json"
  else
    echo -H "Accept: application/vnd.github+json"
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
    echo "$json" | jq -r --arg labels "${PR_LABELS:-}" '
      def ok:
        ($labels | length == 0) or
        (($labels | split(",") | map(gsub("^\\s+|\\s+$";"")) | map(select(length>0))) as $want
         | ($want | length == 0) or any(.labels[].name; . as $n | $want | index($n)));
      .[] | select(ok) | [.number, .head.sha, .head.ref, .html_url, (.base.ref // "")] | @tsv
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
  provider_api_get $(provider_auth_args) "${base}/repos/${owner}/${repo}/pulls/${id}" | jq -r '.head.sha'
}
