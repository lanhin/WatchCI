#!/usr/bin/env bash
# Report CI results back to provider (PR sticky comment, daily commit status).

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

# Commit-status state for a run status. Empty stdout → do not post.
report_daily_status_state() {
  case "$1" in
    success) printf '%s\n' success ;;
    failure|timeout) printf '%s\n' failure ;;
    *) printf '\n' ;;
  esac
}

# One-line description, max 140 chars (GitHub status limit). timeout keeps that word.
report_daily_status_description() {
  local status="$1" exit_code="$2" duration="$3" attempts="$4"
  local label desc
  case "$status" in
    timeout) label=timeout ;;
    *) label="$status" ;;
  esac
  desc="${label} · exit ${exit_code} · ${duration}s · attempts ${attempts}"
  if ((${#desc} > 140)); then
    desc="${desc:0:137}..."
  fi
  printf '%s\n' "$desc"
}

# Issue title shown in the GitCode issue list. Status word stays success/failure/timeout.
report_daily_issue_title() {
  printf '%s\n' "WatchCI daily · $1"
}

# One history row: time, status, sha8, exit, duration, optional detail link.
report_daily_issue_line() {
  local id="$1" status="$2" sha="$3" exit_code="$4" duration="$5" finished="$6"
  local sha8 when link
  sha8="${sha:0:8}"
  when=""
  if [[ -n "$finished" && "$finished" != "null" && "$finished" != "0" ]]; then
    when="$(date -r "$finished" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || date -d "@$finished" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || true)"
  fi
  [[ -n "$when" ]] || when="—"
  link=""
  if [[ -n "${SITE_PUBLIC_URL:-}" && -n "$id" ]]; then
    link=" [详情](${SITE_PUBLIC_URL}/runs/${id}/)"
  fi
  printf '%s\n' "- ${when} ${status} \`${sha8}\` exit ${exit_code} · ${duration}s${link}"
}

# Newest-first lines for the fail streak after the current run, through the latest success.
# Empty when the current run succeeded, or when nothing older qualifies.
report_daily_issue_history() {
  local meta="$1"
  local project ref cur_id status_now runs_dir tmp f
  local finished id status sha exit_code duration started out
  status_now="$(jq -r '.status // empty' "$meta")"
  [[ "$status_now" == "failure" || "$status_now" == "timeout" ]] || return 0
  [[ -n "${DATA_DIR:-}" && -d "$DATA_DIR/runs" ]] || return 0
  project="$(jq -r '.project // empty' "$meta")"
  ref="$(jq -r '.ref // empty' "$meta")"
  cur_id="$(jq -r '.id // empty' "$meta")"
  runs_dir="$DATA_DIR/runs"
  tmp="$(mktemp)"
  for f in "$runs_dir"/*.meta.json; do
    [[ -f "$f" ]] || continue
    jq -r \
      --arg project "$project" \
      --arg ref "$ref" \
      'select(
        .project == $project and .ref == $ref and .source == "daily"
        and (.status == "success" or .status == "failure" or .status == "timeout")
      ) | [(.finished // 0), (.id // ""), .status, (.sha // ""), (.exit_code // 0), (.duration // 0)] | @tsv' \
      "$f" 2>/dev/null >>"$tmp" || true
  done
  started=0
  out=""
  while IFS=$'\t' read -r finished id status sha exit_code duration || [[ -n "${finished:-}" ]]; do
    [[ -n "${finished:-}" ]] || continue
    if [[ "$started" -eq 0 ]]; then
      [[ "$id" == "$cur_id" ]] && started=1
      continue
    fi
    out+="$(report_daily_issue_line "$id" "$status" "$sha" "$exit_code" "$duration" "$finished")"$'\n'
    [[ "$status" == "success" ]] && break
  done < <(sort -t$'\t' -k1,1nr "$tmp")
  rm -f "$tmp"
  printf '%s' "$out"
}

# Issue body: latest summary, plus the fail window when the latest run did not succeed.
report_daily_issue_body() {
  local meta="$1"
  local hist marker
  marker="${WATCHCI_DAILY_ISSUE_MARKER:-<!-- watchci-daily -->}"
  printf '%s\n' "$(report_pr_comment_body "$meta")"
  hist="$(report_daily_issue_history "$meta")"
  if [[ -n "$hist" ]]; then
    printf '\n%s\n%s\n' "### 自上次成功以来" "$hist"
  fi
  printf '\n%s\n' "$marker"
}

# GitHub/Gitee: commit status on the SHA. GitCode: one issue, title+body replaced each day.
# No-op unless POST_DAILY_STATUS and source=daily. API failure returns non-zero; caller warns.
report_daily_status() {
  local run_id="$1"
  local meta src status sha ap state desc url id exit_code duration attempts
  [[ "${POST_DAILY_STATUS:-false}" == "true" || "${POST_DAILY_STATUS:-false}" == "1" ]] || return 0
  meta="$DATA_DIR/runs/${run_id}.meta.json"
  [[ -f "$meta" ]] || return 0
  src="$(jq -r '.source // empty' "$meta")"
  [[ "$src" == "daily" ]] || return 0
  status="$(jq -r '.status // empty' "$meta")"
  state="$(report_daily_status_state "$status")"
  [[ -n "$state" ]] || return 0
  sha="$(jq -r '.sha // empty' "$meta")"
  [[ -n "$sha" && "$sha" != "null" ]] || return 0

  case "${PROVIDER:-}" in
    github|gitee|gitcode) ;;
    *)
      warn "POST_DAILY_STATUS: provider=${PROVIDER:-} not supported, skip"
      return 0
      ;;
  esac

  ap="$WATCHCI_ROOT/adapters/${PROVIDER}.sh"
  [[ -f "$ap" ]] || {
    warn "POST_DAILY_STATUS: missing adapter $ap"
    return 0
  }
  # shellcheck source=/dev/null
  source "$ap"

  if [[ "${PROVIDER}" == "gitcode" ]]; then
    if ! declare -F provider_upsert_daily_issue >/dev/null 2>&1; then
      warn "POST_DAILY_STATUS: provider_upsert_daily_issue missing for gitcode"
      return 0
    fi
    provider_upsert_daily_issue "$(report_daily_issue_title "$status")" "$(report_daily_issue_body "$meta")"
    return
  fi

  if ! declare -F provider_create_commit_status >/dev/null 2>&1; then
    warn "POST_DAILY_STATUS: provider_create_commit_status missing for $PROVIDER"
    return 0
  fi

  id="$(jq -r '.id // empty' "$meta")"
  exit_code="$(jq -r '.exit_code // 0' "$meta")"
  duration="$(jq -r '.duration // 0' "$meta")"
  attempts="$(jq -r '.attempts // 1' "$meta")"
  desc="$(report_daily_status_description "$status" "$exit_code" "$duration" "$attempts")"
  url=""
  if [[ -n "${SITE_PUBLIC_URL:-}" && -n "$id" ]]; then
    url="${SITE_PUBLIC_URL}/runs/${id}/"
  fi
  provider_create_commit_status "$sha" "$state" "$desc" "$url" "watchci/daily"
}
