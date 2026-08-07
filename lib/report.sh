#!/usr/bin/env bash
# Report CI results back to provider (PR sticky comment).

# Build markdown body for a run meta JSON file. Uses SITE_PUBLIC_URL / WATCHCI_COMMENT_MARKER.
# stdin unused; args: meta_path → stdout body.
report_pr_comment_body() {
  local meta="$1"
  local id project status sha duration attempts exit_code finished sha8 link marker headline updated
  marker="${WATCHCI_COMMENT_MARKER:-<!-- watchci -->}"
  id="$(jq -r '.id // empty' "$meta")"
  project="$(jq -r '.project // empty' "$meta")"
  status="$(jq -r '.status // empty' "$meta")"
  sha="$(jq -r '.sha // empty' "$meta")"
  duration="$(jq -r '.duration // 0' "$meta")"
  attempts="$(jq -r '.attempts // 1' "$meta")"
  exit_code="$(jq -r '.exit_code // 0' "$meta")"
  finished="$(jq -r '.finished // empty' "$meta")"
  sha8="${sha:0:8}"
  # local wall clock, same format as site / logs
  updated=""
  if [[ -n "$finished" && "$finished" != "null" ]]; then
    updated="$(date -r "$finished" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$finished" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  fi
  [[ -n "$updated" ]] || updated="$(date '+%Y-%m-%d %H:%M:%S')"
  # emoji + h3: scannable in PR threads across GitHub/Gitee/GitCode
  case "$status" in
    success) headline="### ✅ WatchCI · success" ;;
    failure) headline="### ❌ WatchCI · failure" ;;
    timeout) headline="### ⏰ WatchCI · timeout" ;;
    *)       headline="### WatchCI · ${status}" ;;
  esac
  link=""
  if [[ -n "${SITE_PUBLIC_URL:-}" && -n "$id" ]]; then
    link="- [详情](${SITE_PUBLIC_URL}/runs/${id}/)"
  fi
  printf '%s\n' \
    "$headline" \
    "" \
    "- project: \`${project}\`" \
    "- sha: \`${sha8}\`" \
    "- duration: ${duration}s" \
    "- attempts: ${attempts}" \
    "- exit: ${exit_code}" \
    "- updated: ${updated}"
  if [[ -n "$link" ]]; then
    printf '%s\n' "$link"
  fi
  printf '%s\n' "" "${marker}"
}

# Return 0 if PR sticky is already success for this sha (caller should skip CI).
# Requires project env loaded. API / adapter failure → return 1 (do not skip).
report_pr_should_skip_run() {
  local pr_id="$1" sha="$2"
  local ap match body
  [[ "${SKIP_IF_PR_SUCCESS_COMMENT:-false}" == "true" || "${SKIP_IF_PR_SUCCESS_COMMENT:-false}" == "1" ]] || return 1
  [[ "${POST_PR_COMMENT:-false}" == "true" || "${POST_PR_COMMENT:-false}" == "1" ]] || return 1
  [[ -n "$pr_id" && -n "$sha" ]] || return 1
  case "${PROVIDER:-}" in
    github|gitee|gitcode) ;;
    *) return 1 ;;
  esac
  ap="$WATCHCI_ROOT/adapters/${PROVIDER}.sh"
  [[ -f "$ap" ]] || return 1
  # shellcheck source=/dev/null
  source "$ap"
  declare -F provider_get_pr_sticky_comment >/dev/null 2>&1 || return 1
  declare -F provider_comment_is_success_for_sha >/dev/null 2>&1 || return 1
  match="$(provider_get_pr_sticky_comment "$pr_id")" || return 1
  [[ -n "$match" ]] || return 1
  body="$(jq -r '.body // empty' <<<"$match")"
  [[ -n "$body" ]] || return 1
  provider_comment_is_success_for_sha "$body" "$sha"
}

# After a PR run: upsert sticky comment. No-op unless POST_PR_COMMENT and kind=pr.
# Requires project env already loaded (PROVIDER, OWNER, REPO, TOKEN_ENV, POST_PR_COMMENT).
report_pr_comment() {
  local run_id="$1"
  local meta kind pr_id body status sha ap
  [[ "${POST_PR_COMMENT:-false}" == "true" || "${POST_PR_COMMENT:-false}" == "1" ]] || return 0
  meta="$DATA_DIR/runs/${run_id}.meta.json"
  [[ -f "$meta" ]] || return 0
  kind="$(jq -r '.kind // empty' "$meta")"
  pr_id="$(jq -r '.pr_id // empty' "$meta")"
  [[ "$kind" == "pr" && -n "$pr_id" && "$pr_id" != "null" ]] || return 0

  case "${PROVIDER:-}" in
    github|gitee|gitcode) ;;
    *)
      warn "POST_PR_COMMENT: provider=${PROVIDER:-} not supported for PR comments, skip"
      return 0
      ;;
  esac

  ap="$WATCHCI_ROOT/adapters/${PROVIDER}.sh"
  [[ -f "$ap" ]] || {
    warn "POST_PR_COMMENT: missing adapter $ap"
    return 0
  }
  # shellcheck source=/dev/null
  source "$ap"
  if ! declare -F provider_upsert_pr_comment >/dev/null 2>&1; then
    warn "POST_PR_COMMENT: provider_upsert_pr_comment missing for $PROVIDER"
    return 0
  fi

  status="$(jq -r '.status // empty' "$meta")"
  sha="$(jq -r '.sha // empty' "$meta")"
  body="$(report_pr_comment_body "$meta")"
  provider_upsert_pr_comment "$pr_id" "$body" "$status" "$sha"
}
