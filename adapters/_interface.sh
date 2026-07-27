# Adapter interface (document only — each provider.sh implements these).
#
# provider_auth_header
#   Prints one HTTP header line value or full "Header: value" pairs via stdout
#   used by curl -H. Convention: print the Authorization/Private-Token header
#   value arguments for curl, e.g. multiple -H via provider_curl_auth helper.
#
# provider_list_open_prs
#   Prints TSV lines: pr_id \t head_sha \t branch \t url
#   Uses env from loaded project: OWNER REPO API_BASE TOKEN_ENV PROJECT_ID PR_LABELS
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

provider_api_get() {
  local url="$1"
  shift
  curl -fsSL "$@" "$url"
}
