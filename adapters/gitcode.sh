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
        (.html_url // .url // ""),
        (.base.ref // .target_branch // "")
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

# Upsert sticky WatchCI comment on a PR (GitCode pulls comments API).
# Auth: access_token query (same as official curl), not Bearer.
# GET/POST .../pulls/{number}/comments ; PATCH .../pulls/comments/{id}
provider_upsert_pr_comment() {
  local pr_id="$1" body="$2" status="${3:-}" sha="${4:-}"
  local base owner repo tok page json count cid old_body match payload url
  base="$(provider_default_api_base)"
  owner="${OWNER:?OWNER required}"
  repo="${REPO:?REPO required}"
  tok="$(provider_token)"
  [[ -n "$pr_id" ]] || return 1
  cid=""
  old_body=""
  page=1
  while [[ "$page" -le 5 ]]; do
    url="${base}/repos/${owner}/${repo}/pulls/${pr_id}/comments?page=${page}&per_page=100&comment_type=pr_comment"
    [[ -n "$tok" ]] && url="${url}&access_token=${tok}"
    json="$(provider_api_get -H "Accept: application/json" "$url")" || return 1
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
    provider_api_json -X PATCH \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$url" >/dev/null
  else
    url="${base}/repos/${owner}/${repo}/pulls/${pr_id}/comments"
    [[ -n "$tok" ]] && url="${url}?access_token=${tok}"
    provider_api_json -X POST \
      -H "Accept: application/json" \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "$url" >/dev/null
  fi
}
