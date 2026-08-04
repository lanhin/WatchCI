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
    echo "$json" | provider_jq_skip_wip | jq -r '
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

# Upsert sticky WatchCI comment on a PR (Gitee pulls comments API).
# Verified curl shape: access_token query + Content-Type: application/json;charset=UTF-8
# GET/POST .../pulls/{number}/comments ; PATCH .../pulls/comments/{id}
provider_upsert_pr_comment() {
  local pr_id="$1" body="$2" status="${3:-}" sha="${4:-}"
  local base owner repo tok page json count cid old_body match payload url
  local hdr='Content-Type: application/json;charset=UTF-8'
  base="$(provider_default_api_base)"
  owner="${OWNER:?OWNER required}"
  repo="${REPO:?REPO required}"
  tok="$(provider_token)"
  [[ -n "$pr_id" ]] || return 1
  cid=""
  old_body=""
  page=1
  while [[ "$page" -le 5 ]]; do
    url="${base}/repos/${owner}/${repo}/pulls/${pr_id}/comments?page=${page}&per_page=100"
    [[ -n "$tok" ]] && url="${url}&access_token=${tok}"
    json="$(provider_api_get -H "$hdr" "$url")" || return 1
    match="$(echo "$json" | provider_comment_find_match)"
    if [[ -n "$match" ]]; then
      cid="$(jq -r '.id // empty' <<<"$match")"
      old_body="$(jq -r '.body // empty' <<<"$match")"
      break
    fi
    count="$(echo "$json" | jq 'length')"
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
  payload="$(jq -n --arg body "$body" '{body:$body}')"
  if [[ -n "$cid" ]]; then
    if provider_comment_skip_downgrade "$old_body" "$status" "$sha"; then
      return 0
    fi
    url="${base}/repos/${owner}/${repo}/pulls/comments/${cid}"
    [[ -n "$tok" ]] && url="${url}?access_token=${tok}"
    provider_api_json -X PATCH -H "$hdr" -d "$payload" "$url" >/dev/null
  else
    url="${base}/repos/${owner}/${repo}/pulls/${pr_id}/comments"
    [[ -n "$tok" ]] && url="${url}?access_token=${tok}"
    provider_api_json -X POST -H "$hdr" -d "$payload" "$url" >/dev/null
  fi
}

