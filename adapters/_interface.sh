# Adapter interface (document only — each provider.sh implements these).
#
# provider_auth_header
#   Prints one HTTP header line value or full "Header: value" pairs via stdout
#   used by curl -H. Convention: print the Authorization/Private-Token header
#   value arguments for curl, e.g. multiple -H via provider_curl_auth helper.
#
# provider_list_open_prs
#   Prints TSV lines: pr_id \t head_sha \t head_branch \t url \t base_branch
#   Uses env from loaded project: OWNER REPO API_BASE TOKEN_ENV PROJECT_ID PR_LABELS
#   Caller filters by base_branch against BRANCHES.
#   Adapters drop WIP/draft PRs via provider_jq_skip_wip (title ^[WIP], draft, work_in_progress).
#
# provider_pr_head_sha <id>   (optional)
#   Prints head sha for one PR/MR.
#
# provider_upsert_pr_comment <pr_id> <body> <status> <sha>   (optional; github/gitee/gitcode)
#   Create or update sticky PR comment whose body contains WATCHCI_COMMENT_MARKER.
#   Skips PATCH when new status is failure/timeout, existing comment is success, same sha8.
#
# Token is read from environment variable named by TOKEN_ENV (never from conf value).

provider_token() {
  local env_name="${TOKEN_ENV:-}"
  if [[ -z "$env_name" ]]; then
    echo ""
    return 0
  fi
  printenv "$env_name" || true
}

# Drop WIP/draft PRs before TSV emit. stdin: PR JSON array → stdout: filtered array.
provider_jq_skip_wip() {
  jq '[.[] | select(
    ((.title // "") | test("^\\[WIP\\]"; "i") | not)
    and ((.draft // false) != true)
    and ((.work_in_progress // false) != true)
  )]'
}

# Redact secrets for log lines (Bearer / PRIVATE-TOKEN / access_token=).
_provider_curl_cmd_redacted() {
  local a s="" redact_next=0
  for a in "$@"; do
    if [[ "$redact_next" -eq 1 ]]; then
      a="***"
      redact_next=0
    else
      case "$a" in
        Authorization:*[Bb]earer*) a="Authorization: Bearer ***" ;;
        # word-split of "Authorization: Bearer TOKEN" leaves Bearer + token separate
        [Bb]earer) a="Bearer"; redact_next=1 ;;
        PRIVATE-TOKEN:*) a="PRIVATE-TOKEN: ***" ;;
        *access_token=*)
          a="$(printf '%s' "$a" | sed -E 's/access_token=[^&"]+/access_token=***/g')"
          ;;
      esac
    fi
    s+=" $(printf '%q' "$a")"
  done
  echo "curl -fsSL${s}"
}

# GET with -fsSL. On HTTP 502, warn with redacted command line.
provider_api_get() {
  local err ec=0
  exec 3>&1
  err="$(curl -fsSL "$@" 2>&1 1>&3)" || ec=$?
  exec 3>&-
  if [[ "$ec" -ne 0 ]]; then
    [[ -n "$err" ]] && echo "$err" >&2
    if [[ "$err" == *'returned error: 502'* ]]; then
      warn "curl 502 command: $(_provider_curl_cmd_redacted "$@")"
    fi
    return "$ec"
  fi
  return 0
}

# POST/PATCH (or any method via curl args) with -fsSL. Same 502/redact behavior as GET.
provider_api_json() {
  local err ec=0
  exec 3>&1
  err="$(curl -fsSL "$@" 2>&1 1>&3)" || ec=$?
  exec 3>&-
  if [[ "$ec" -ne 0 ]]; then
    [[ -n "$err" ]] && echo "$err" >&2
    if [[ "$err" == *'returned error: 502'* ]]; then
      warn "curl 502 command: $(_provider_curl_cmd_redacted "$@")"
    fi
    return "$ec"
  fi
  return 0
}

# Hidden marker in PR comment body for sticky upsert.
WATCHCI_COMMENT_MARKER='<!-- watchci -->'

# stdin: comments JSON array → stdout: compact JSON {id,body} of first sticky, or empty.
provider_comment_find_match() {
  jq -c --arg m "$WATCHCI_COMMENT_MARKER" '
    map(select((.body // "") | contains($m))) | .[0] | if . then {id, body} else empty end
  '
}

# stdin: comments JSON array → stdout: first matching comment id, or empty.
provider_comment_find_id() {
  provider_comment_find_match | jq -r '.id // empty'
}

# Return 0 = skip PATCH (do not overwrite success with failure/timeout on same sha8).
provider_comment_skip_downgrade() {
  local old_body="$1" new_status="$2" new_sha="$3"
  local old_status old_sha8 new_sha8
  case "$new_status" in
    failure|timeout) ;;
    *) return 1 ;;
  esac
  old_status="$(printf '%s\n' "$old_body" | sed -n 's/.*WatchCI · \([a-z]*\).*/\1/p' | head -1)"
  [[ "$old_status" == "success" ]] || return 1
  old_sha8="$(printf '%s\n' "$old_body" | sed -n 's/.*sha: `\([0-9a-fA-F]*\)`.*/\1/p' | head -1)"
  [[ -n "$old_sha8" ]] || return 1
  new_sha8="${new_sha:0:8}"
  [[ "$old_sha8" == "$new_sha8" ]] || return 1
  return 0
}

