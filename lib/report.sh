#!/usr/bin/env bash
# Report CI results back to provider (PR sticky comment).

# Build markdown body for a run meta JSON file. Uses SITE_PUBLIC_URL / WATCHCI_COMMENT_MARKER.
# stdin unused; args: meta_path → stdout body.
report_pr_comment_body() {
  local meta="$1"
  local id project status sha duration attempts exit_code sha8 link marker headline
  marker="${WATCHCI_COMMENT_MARKER:-<!-- watchci -->}"
  id="$(jq -r '.id // empty' "$meta")"
  project="$(jq -r '.project // empty' "$meta")"
  status="$(jq -r '.status // empty' "$meta")"
  sha="$(jq -r '.sha // empty' "$meta")"
  duration="$(jq -r '.duration // 0' "$meta")"
  attempts="$(jq -r '.attempts // 1' "$meta")"
  exit_code="$(jq -r '.exit_code // 0' "$meta")"
  sha8="${sha:0:8}"
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
    "- exit: ${exit_code}"
  if [[ -n "$link" ]]; then
    printf '%s\n' "$link"
  fi
  printf '%s\n' "" "${marker}"
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
