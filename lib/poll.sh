#!/usr/bin/env bash
# Poll one project: git fetch branches + optional PR heads via adapter.

# shellcheck source=common.sh
# Expected: project already loaded (NAME, REPO_URL, ...), state/events sourced.

_adapter_path() {
  echo "$WATCHCI_ROOT/adapters/${PROVIDER}.sh"
}

load_adapter() {
  local ap
  ap="$(_adapter_path)"
  [[ -f "$ap" ]] || die "adapter not found: $ap"
  # shellcheck disable=SC1090
  source "$ap"
}

ensure_clone() {
  if [[ -d "$CLONE_DIR/.git" ]]; then
    return 0
  fi
  info "cloning $REPO_URL -> $CLONE_DIR"
  mkdir -p "$(dirname "$CLONE_DIR")"
  git clone "$REPO_URL" "$CLONE_DIR" || die "git clone failed for $NAME"
}

# True if branch name matches BRANCHES (comma-separated; supports * glob).
branch_matches_watch() {
  local name="$1"
  local patterns="${2:-${BRANCHES:-main}}"
  local pat
  local -a pats=()
  local oldifs="$IFS"
  IFS=','
  # shellcheck disable=SC2206
  pats=($patterns)
  IFS="$oldifs"
  if [[ ${#pats[@]} -eq 0 || -z "${pats[0]:-}" ]]; then
    pats=(main)
  fi
  for pat in "${pats[@]}"; do
    pat="${pat#"${pat%%[![:space:]]*}"}"
    pat="${pat%"${pat##*[![:space:]]}"}"
    [[ -z "$pat" ]] && continue
    # shellcheck disable=SC2254
    case "$name" in
      $pat) return 0 ;;
    esac
  done
  return 1
}

# Expand BRANCHES patterns against remote refs after fetch.
match_remote_branches() {
  local patterns="$1"
  local short
  while IFS= read -r short; do
    [[ -z "$short" || "$short" == "HEAD" ]] && continue
    branch_matches_watch "$short" "$patterns" && echo "$short"
  done < <(git -C "$CLONE_DIR" for-each-ref --format='%(refname:short)' refs/remotes/origin/ | sed 's|^origin/||') | sort -u
}

poll_branches() {
  local branch sha old
  git -C "$CLONE_DIR" fetch --prune origin 2>&1 | while read -r line; do info "git: $line"; done || {
    warn "git fetch failed for $NAME"
    return 1
  }
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    sha="$(git -C "$CLONE_DIR" rev-parse "refs/remotes/origin/$branch" 2>/dev/null || true)"
    [[ -n "$sha" ]] || continue
    old="$(state_get_sha branch "$branch")"
    if [[ "$old" != "$sha" ]]; then
      info "branch change $NAME $branch ${old:0:8} -> ${sha:0:8}"
      event_enqueue "$NAME" branch "$branch" "$sha" "" poll
      state_set branch "$branch" "$sha"
    fi
  done < <(match_remote_branches "${BRANCHES:-main}")
}

poll_prs() {
  [[ "${WATCH_PRS}" == "true" || "${WATCH_PRS}" == "1" ]] || return 0
  load_adapter
  local pr_id head_sha branch url base old
  while IFS=$'\t' read -r pr_id head_sha branch url base; do
    [[ -z "$pr_id" || -z "$head_sha" ]] && continue
    # Only PRs whose target (base) is in BRANCHES — same watch list as push.
    if ! branch_matches_watch "${base:-}"; then
      continue
    fi
    old="$(state_get_sha pr "$pr_id")"
    if [[ "$old" != "$head_sha" ]]; then
      info "pr change $NAME #$pr_id base=${base:-?} ${old:0:8} -> ${head_sha:0:8}"
      event_enqueue "$NAME" pr "${branch:-pr-$pr_id}" "$head_sha" "$pr_id" poll "$base"
      state_set pr "$pr_id" "$head_sha"
    fi
  done < <(provider_list_open_prs)
}

# Poll a single project by conf file path.
poll_project_file() {
  local file="$1"
  load_project_file "$file"
  validate_project || return 0
  state_ensure
  ensure_clone
  poll_branches
  poll_prs || warn "PR poll failed for $NAME (continuing)"
}

# Poll all enabled projects.
poll_all() {
  local f
  while IFS= read -r f; do
    (
      # shellcheck source=state.sh
      source "$WATCHCI_ROOT/lib/state.sh"
      # shellcheck source=events.sh
      source "$WATCHCI_ROOT/lib/events.sh"
      poll_project_file "$f"
    ) || warn "poll failed for $f"
  done < <(list_project_files)
}
