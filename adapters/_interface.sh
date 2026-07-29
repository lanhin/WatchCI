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
#
# provider_pr_head_sha <id>   (optional)
#   Prints head sha for one PR/MR.
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

# Redact secrets for log lines (Bearer / PRIVATE-TOKEN / access_token=).
_provider_curl_cmd_redacted() {
  local a s=""
  for a in "$@"; do
    case "$a" in
      Authorization:*[Bb]earer*) a="Authorization: Bearer ***" ;;
      PRIVATE-TOKEN:*) a="PRIVATE-TOKEN: ***" ;;
      *access_token=*)
        a="$(printf '%s' "$a" | sed -E 's/access_token=[^&"]+/access_token=***/g')"
        ;;
    esac
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
