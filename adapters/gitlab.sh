#!/usr/bin/env bash
# GitLab merge requests adapter.
# shellcheck source=_interface.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/_interface.sh"

provider_default_api_base() {
  echo "${API_BASE:-https://gitlab.com/api/v4}"
}

# PROJECT_ID preferred; else URL-encode OWNER/REPO
_gitlab_project_path() {
  if [[ -n "${PROJECT_ID:-}" ]]; then
    echo "$PROJECT_ID"
  else
    local owner="${OWNER:?}" repo="${REPO:?}"
    python3 -c "import urllib.parse; print(urllib.parse.quote('${owner}/${repo}', safe=''))"
  fi
}

provider_auth_args() {
  local tok
  tok="$(provider_token)"
  if [[ -n "$tok" ]]; then
    echo -H "PRIVATE-TOKEN: $tok"
  fi
}

provider_list_open_prs() {
  local base proj page json
  base="$(provider_default_api_base)"
  proj="$(_gitlab_project_path)"
  page=1
  while true; do
    # shellcheck disable=SC2046
    json="$(provider_api_get $(provider_auth_args) \
      "${base}/projects/${proj}/merge_requests?state=opened&per_page=100&page=${page}")" || return 1
    local count
    count="$(echo "$json" | jq 'length')"
    [[ "$count" -eq 0 ]] && break
    echo "$json" | jq -r '
      .[] | [.iid, .sha, .source_branch, (.web_url // ""), (.target_branch // "")] | @tsv
    '
    [[ "$count" -lt 100 ]] && break
    page=$((page + 1))
  done
}

provider_pr_head_sha() {
  local id="$1" base proj
  base="$(provider_default_api_base)"
  proj="$(_gitlab_project_path)"
  # shellcheck disable=SC2046
  provider_api_get $(provider_auth_args) \
    "${base}/projects/${proj}/merge_requests/${id}" | jq -r '.sha'
}
