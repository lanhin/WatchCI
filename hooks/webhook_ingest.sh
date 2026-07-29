#!/usr/bin/env bash
# Map provider webhook payloads to WatchCI event JSON (stdin → stdout).
# Usage:
#   cat payload.json | hooks/webhook_ingest.sh github push
#   hooks/webhook_ingest.sh github pull_request < payload.json
#
# Output: one standard event JSON object (or empty if ignored).
# Caller should write the result to $DATA_DIR/events/pending/<id>.json
# and ensure project name mapping (env WATCHCI_PROJECT or --project).
set -euo pipefail

PROVIDER="${1:-}"
EVENT="${2:-}"
PROJECT="${WATCHCI_PROJECT:-${3:-}}"

if [[ -z "$PROVIDER" || -z "$EVENT" ]]; then
  echo "usage: webhook_ingest.sh <provider> <event> [project]" >&2
  exit 2
fi

payload="$(cat)"

if ! command -v jq >/dev/null 2>&1; then
  echo "jq required" >&2
  exit 1
fi

case "$PROVIDER/$EVENT" in
  github/push)
    # branch push → kind=branch
    ref="$(echo "$payload" | jq -r '.ref // empty')"
    sha="$(echo "$payload" | jq -r '.after // empty')"
    branch="${ref#refs/heads/}"
    [[ "$ref" == refs/heads/* ]] || exit 0
    [[ "$sha" != "0000000000000000000000000000000000000000" ]] || exit 0
    jq -n \
      --arg project "$PROJECT" \
      --arg ref "$branch" \
      --arg sha "$sha" \
      --argjson ts "$(date +%s)" \
      '{project:$project, kind:"branch", ref:$ref, pr_id:null, sha:$sha, source:"webhook", ts:$ts}'
    ;;
  github/pull_request)
    action="$(echo "$payload" | jq -r '.action // empty')"
    case "$action" in
      opened|synchronize|reopened) ;;
      *) exit 0 ;;
    esac
    pr_id="$(echo "$payload" | jq -r '.pull_request.number // empty')"
    sha="$(echo "$payload" | jq -r '.pull_request.head.sha // empty')"
    branch="$(echo "$payload" | jq -r '.pull_request.head.ref // empty')"
    base_ref="$(echo "$payload" | jq -r '.pull_request.base.ref // empty')"
    # Optional: WATCHCI_BRANCHES=main,release/* — skip PRs not targeting watched bases.
    if [[ -n "${WATCHCI_BRANCHES:-}" && -n "$base_ref" ]]; then
      matched=0
      oldifs="$IFS"
      IFS=','
      # shellcheck disable=SC2206
      pats=($WATCHCI_BRANCHES)
      IFS="$oldifs"
      for pat in "${pats[@]}"; do
        pat="${pat#"${pat%%[![:space:]]*}"}"
        pat="${pat%"${pat##*[![:space:]]}"}"
        [[ -z "$pat" ]] && continue
        # shellcheck disable=SC2254
        case "$base_ref" in
          $pat) matched=1; break ;;
        esac
      done
      [[ "$matched" -eq 1 ]] || exit 0
    fi
    jq -n \
      --arg project "$PROJECT" \
      --arg ref "$branch" \
      --arg sha "$sha" \
      --arg pr_id "$pr_id" \
      --arg base "$base_ref" \
      --argjson ts "$(date +%s)" \
      '{project:$project, kind:"pr", ref:$ref, pr_id:$pr_id, sha:$sha, source:"webhook", base:(if $base=="" then null else $base end), ts:$ts}'
    ;;
  *)
    # Skeleton for gitee/gitlab/gitcode — map similarly when needed.
    echo "unsupported provider/event: $PROVIDER/$EVENT (stub)" >&2
    exit 0
    ;;
esac
