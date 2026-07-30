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
    json="$(provider_api_get "$url")" || return 1
    local count
    count="$(echo "$json" | jq 'length')"
    [[ "$count" -eq 0 ]] && break
    echo "$json" | jq -r '
      .[] | [.number, .head.sha, .head.ref, (.html_url // .url // ""), (.base.ref // "")] | @tsv
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
  provider_api_get "$url" | jq -r '.head.sha'
}

# Upsert sticky WatchCI comment on a PR (Gitee pulls comments API + access_token).
# Docs: GET/POST .../pulls/{number}/comments ; PATCH .../pulls/comments/{id}
provider_upsert_pr_comment() {
  local pr_id="$1" body="$2"
  local base owner repo tok page json count cid payload url q
  base="$(provider_default_api_base)"
  owner="${OWNER:?OWNER required}"
  repo="${REPO:?REPO required}"
  tok="$(provider_token)"
  [[ -n "$pr_id" ]] || return 1
  q=""
  [[ -n "$tok" ]] && q="?access_token=${tok}"
  cid=""
  page=1
  while [[ "$page" -le 5 ]]; do
    url="${base}/repos/${owner}/${repo}/pulls/${pr_id}/comments?per_page=100&page=${page}"
    [[ -n "$tok" ]] && url="${url}&access_token=${tok}"
    json="$(provider_api_get "$url")" || return 1
    cid="$(echo "$json" | provider_comment_find_id)"
    [[ -n "$cid" ]] && break
    count="$(echo "$json" | jq 'length')"
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
  payload="$(jq -n --arg body "$body" '{body:$body}')"
  if [[ -n "$cid" ]]; then
    url="${base}/repos/${owner}/${repo}/pulls/comments/${cid}${q}"
    provider_api_json -X PATCH -H "Content-Type: application/json" -d "$payload" "$url" >/dev/null
  else
    url="${base}/repos/${owner}/${repo}/pulls/${pr_id}/comments${q}"
    provider_api_json -X POST -H "Content-Type: application/json" -d "$payload" "$url" >/dev/null
  fi
}

