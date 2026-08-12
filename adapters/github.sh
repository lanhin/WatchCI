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
    echo "$json" | provider_jq_skip_wip | jq -r --arg labels "${PR_LABELS:-}" '
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

# Find sticky WatchCI comment on a PR. stdout: compact JSON {id,body} or empty.
# GitHub: PR conversation comments use the Issues comments API (PRs are issues).
provider_get_pr_sticky_comment() {
  local pr_id="$1"
  local base owner repo page json count match
  base="$(provider_default_api_base)"
  owner="${OWNER:?OWNER required}"
  repo="${REPO:?REPO required}"
  [[ -n "$pr_id" ]] || return 1
  page=1
  while [[ "$page" -le 5 ]]; do
    # shellcheck disable=SC2046
    json="$(provider_api_get $(provider_auth_args) \
      "${base}/repos/${owner}/${repo}/issues/${pr_id}/comments?per_page=100&page=${page}")" || return 1
    match="$(echo "$json" | provider_comment_find_match)"
    if [[ -n "$match" ]]; then
      printf '%s\n' "$match"
      return 0
    fi
    count="$(echo "$json" | jq 'length')"
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
  return 0
}

# Upsert sticky WatchCI comment on a PR.
provider_upsert_pr_comment() {
  local pr_id="$1" body="$2" status="${3:-}" sha="${4:-}"
  local base owner repo cid old_body match payload
  base="$(provider_default_api_base)"
  owner="${OWNER:?OWNER required}"
  repo="${REPO:?REPO required}"
  [[ -n "$pr_id" ]] || return 1
  match="$(provider_get_pr_sticky_comment "$pr_id")" || return 1
  cid=""
  old_body=""
  if [[ -n "$match" ]]; then
    cid="$(jq -r '.id // empty' <<<"$match")"
    old_body="$(jq -r '.body // empty' <<<"$match")"
  fi
  payload="$(jq -n --arg body "$body" '{body:$body}')"
  if [[ -n "$cid" ]]; then
    if provider_comment_skip_stale_sha "$old_body" "$sha" "$pr_id"; then
      return 0
    fi
    if provider_comment_skip_downgrade "$old_body" "$status" "$sha"; then
      return 0
    fi
    # shellcheck disable=SC2046
    provider_api_json $(provider_auth_args) -X PATCH \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${base}/repos/${owner}/${repo}/issues/comments/${cid}" >/dev/null
  else
    # shellcheck disable=SC2046
    provider_api_json $(provider_auth_args) -X POST \
      -H "Content-Type: application/json" \
      -d "$payload" \
      "${base}/repos/${owner}/${repo}/issues/${pr_id}/comments" >/dev/null
  fi
}

