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

# True if tip sha is covered by a successful PR CI run (FF tip or merge^2).
# Uses local run metas only — squash/rebase-merge won't match (still enqueue).
_successful_pr_shas() {
  local meta p k st s
  [[ -d "$DATA_DIR/runs" ]] || return 0
  for meta in "$DATA_DIR/runs"/*.meta.json; do
    [[ -f "$meta" ]] || continue
    if command -v jq >/dev/null 2>&1; then
      p="$(jq -r '.project // empty' "$meta")"
      [[ "$p" == "$NAME" ]] || continue
      k="$(jq -r '.kind // empty' "$meta")"
      [[ "$k" == "pr" ]] || continue
      st="$(jq -r '.status // empty' "$meta")"
      [[ "$st" == "success" ]] || continue
      s="$(jq -r '.sha // empty' "$meta")"
      [[ -n "$s" ]] && echo "$s"
    fi
  done
}

# Return 0 if new_sha looks like a successful-PR merge (skip branch re-run).
_pr_ci_covers_branch_tip() {
  local new_sha="$1"
  local s second
  while IFS= read -r s; do
    [[ -z "$s" ]] && continue
    [[ "$new_sha" == "$s" ]] && return 0
  done < <(_successful_pr_shas)
  # merge commit: second parent == PR head we tested
  if git -C "$CLONE_DIR" rev-parse -q --verify "${new_sha}^2" >/dev/null 2>&1; then
    second="$(git -C "$CLONE_DIR" rev-parse "${new_sha}^2" 2>/dev/null || true)"
    [[ -n "$second" ]] || return 1
    while IFS= read -r s; do
      [[ -z "$s" ]] && continue
      [[ "$second" == "$s" ]] && return 0
    done < <(_successful_pr_shas)
  fi
  return 1
}

poll_branches() {
  local branch sha old run_id
  # See runner.sh: avoid on-demand submodule recurse breaking fetch for new submodule paths.
  git -C "$CLONE_DIR" fetch --prune --no-recurse-submodules origin 2>&1 | while read -r line; do info "git: $line"; done || {
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
      run_id="$(state_get_run_id branch "$branch")"
      # Skip re-run when a successful PR CI already covered this tip (FF or merge^2).
      # First branch run (no last_run_id) always enqueues.
      if [[ -n "$run_id" ]] && _pr_ci_covers_branch_tip "$sha"; then
        info "skip branch enqueue $NAME $branch sha=${sha:0:8} (covered by successful PR CI)"
        state_set branch "$branch" "$sha"
      else
        event_enqueue "$NAME" branch "$branch" "$sha" "" poll
        state_set branch "$branch" "$sha"
      fi
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

# True if a finished branch run for ref exists with finished date == today (local).
_branch_run_finished_today() {
  local ref="$1"
  local today meta p k r fin day
  today="$(date +%Y-%m-%d)"
  [[ -d "$DATA_DIR/runs" ]] || return 1
  for meta in "$DATA_DIR/runs"/*.meta.json; do
    [[ -f "$meta" ]] || continue
    if command -v jq >/dev/null 2>&1; then
      p="$(jq -r '.project // empty' "$meta")"
      [[ "$p" == "$NAME" ]] || continue
      k="$(jq -r '.kind // empty' "$meta")"
      [[ "$k" == "branch" ]] || continue
      r="$(jq -r '.ref // empty' "$meta")"
      [[ "$r" == "$ref" ]] || continue
      fin="$(jq -r '.finished // empty' "$meta")"
      [[ -n "$fin" && "$fin" != "null" ]] || continue
      day="$(date -r "$fin" +%Y-%m-%d 2>/dev/null || date -d "@$fin" +%Y-%m-%d 2>/dev/null || true)"
      [[ "$day" == "$today" ]] && return 0
    fi
  done
  return 1
}

# HH:MM <= now HH:MM (lexicographic works for zero-padded times).
_daily_at_reached() {
  local want="${1:-02:00}"
  local now
  now="$(date +%H:%M)"
  [[ "$now" > "$want" || "$now" == "$want" ]]
}

# Optional daily branch top-up: enqueue once after DAILY_AT if no finished branch run today.
poll_daily() {
  local branch sha
  [[ "${DAILY_ENABLE}" == "true" || "${DAILY_ENABLE}" == "1" ]] || return 0
  _daily_at_reached "${DAILY_AT:-02:00}" || return 0
  branch="${DAILY_BRANCH:-main}"
  if ! branch_matches_watch "$branch"; then
    warn "DAILY_BRANCH=$branch not in BRANCHES for $NAME, skip daily"
    return 0
  fi
  sha="$(git -C "$CLONE_DIR" rev-parse "refs/remotes/origin/$branch" 2>/dev/null || true)"
  [[ -n "$sha" ]] || return 0
  if _branch_run_finished_today "$branch"; then
    return 0
  fi
  # Always enqueue when due — do not skip for busy lock; pending drains later.
  event_enqueue "$NAME" branch "$branch" "$sha" "" daily
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
  poll_daily || warn "daily poll failed for $NAME (continuing)"
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
