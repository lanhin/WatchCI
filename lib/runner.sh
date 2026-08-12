#!/usr/bin/env bash
# Run CI for pending events.

# shellcheck source=site.sh — sourced by caller

_find_project_file_by_name() {
  local want="$1" f
  while IFS= read -r f; do
    if grep -qE "^NAME=${want}$|^NAME=\"${want}\"$|^NAME='${want}'$" "$f" 2>/dev/null \
      || [[ "$(basename "$f" .conf)" == "$want" ]]; then
      # Prefer explicit NAME match
      if grep -qE "^NAME=${want}$|^NAME=\"${want}\"$|^NAME='${want}'$" "$f" 2>/dev/null; then
        echo "$f"
        return 0
      fi
    fi
  done < <(list_project_files)
  # fallback: filename
  [[ -f "$PROJECTS_DIR/${want}.conf" ]] && { echo "$PROJECTS_DIR/${want}.conf"; return 0; }
  return 1
}

_resolve_script() {
  local script="$1"
  if [[ "$script" = /* ]]; then
    echo "$script"
  elif [[ -f "$CLONE_DIR/$script" ]]; then
    echo "$CLONE_DIR/$script"
  elif [[ -f "$WATCHCI_ROOT/$script" ]]; then
    echo "$WATCHCI_ROOT/$script"
  else
    echo "$CLONE_DIR/$script"
  fi
}

# Fill _SCRIPT_CMDLINE=(resolved_path [args...]) from SCRIPT.
# ponytail: first whitespace token = path; rest = args. Path itself must not contain spaces.
_script_cmdline() {
  local file rest
  file="${SCRIPT%%[[:space:]]*}"
  rest="${SCRIPT#"$file"}"
  rest="${rest#"${rest%%[![:space:]]*}"}"
  [[ -n "$file" ]] || return 1
  _SCRIPT_CMDLINE=("$( _resolve_script "$file" )")
  if [[ -n "$rest" ]]; then
    local -a args
    read -r -a args <<< "$rest"
    _SCRIPT_CMDLINE+=("${args[@]}")
  fi
}

# Remote ref that carries a PR/MR head commit (API sha alone is not enough to fetch).
_pr_head_ref() {
  local id="$1"
  case "${PROVIDER}" in
    gitlab|gitcode) echo "refs/merge-requests/${id}/head" ;;
    *) echo "refs/pull/${id}/head" ;; # github / gitee
  esac
}

# First BRANCHES entry, or main (same default as poll).
_pr_base_branch() {
  local first
  first="${BRANCHES%%,*}"
  first="${first#"${first%%[![:space:]]*}"}"
  first="${first%"${first##*[![:space:]]}"}"
  echo "${first:-main}"
}

# Reset clone to clean detached origin/<base>; no local branches left dirty.
_clone_cleanup() {
  [[ -n "${CLONE_DIR:-}" && -d "${CLONE_DIR}/.git" ]] || return 0
  git -C "$CLONE_DIR" merge --abort >/dev/null 2>&1 || true
  git -C "$CLONE_DIR" rebase --abort >/dev/null 2>&1 || true
  local base
  base="$(_pr_base_branch)"
  if git -C "$CLONE_DIR" rev-parse --verify "origin/$base" >/dev/null 2>&1; then
    git -C "$CLONE_DIR" checkout --detach "origin/$base" >/dev/null 2>&1 || true
  fi
  git -C "$CLONE_DIR" reset --hard >/dev/null 2>&1 || true
  git -C "$CLONE_DIR" clean -fd >/dev/null 2>&1 || true
}

# Fetch + detach to event sha. PR: merge into base (conflict → fail); detached only (no temp branch).
# base_override: PR target branch from event (preferred over first BRANCHES entry).
_checkout_sha() {
  local sha="$1" kind="$2" pr_id="$3" log_path="$4" base_override="${5:-}"
  local pr_ref base

  # --no-recurse-submodules: PR adding a new submodule leaves no worktree yet;
  # on-demand recurse then fails (cannot chdir) and aborts a successful FETCH_HEAD.
  if ! git -C "$CLONE_DIR" fetch --prune --no-recurse-submodules origin >>"$log_path" 2>&1; then
    echo "fetch failed" >>"$log_path"
    return 1
  fi

  if [[ "$kind" == "pr" && -n "$pr_id" ]]; then
    pr_ref="$(_pr_head_ref "$pr_id")"
    echo "fetch pr head $pr_ref" >>"$log_path"
    if ! git -C "$CLONE_DIR" fetch --no-recurse-submodules origin "$pr_ref" >>"$log_path" 2>&1; then
      echo "pr fetch failed ref=$pr_ref" >>"$log_path"
      return 1
    fi
    base="${base_override:-$(_pr_base_branch)}"
    echo "pr merge onto origin/$base" >>"$log_path"
    if ! git -C "$CLONE_DIR" rev-parse --verify "origin/$base" >/dev/null 2>&1; then
      echo "pr base missing: origin/$base" >>"$log_path"
      return 1
    fi
    if ! git -C "$CLONE_DIR" checkout --detach "origin/$base" >>"$log_path" 2>&1; then
      echo "checkout base failed: origin/$base" >>"$log_path"
      return 1
    fi
    # Allow merge commit when diverged; only conflicts (or other merge errors) fail.
    if ! git -C "$CLONE_DIR" -c core.editor=true merge --no-edit \
      -m "WatchCI: merge $sha into $base" "$sha" >>"$log_path" 2>&1; then
      echo "merge failed (conflicts or error; resolve against $base)" >>"$log_path"
      git -C "$CLONE_DIR" merge --abort >>"$log_path" 2>&1 || \
        git -C "$CLONE_DIR" reset --hard "origin/$base" >>"$log_path" 2>&1 || true
      return 1
    fi
    return 0
  fi

  if ! git -C "$CLONE_DIR" checkout --detach "$sha" >>"$log_path" 2>&1; then
    echo "checkout failed" >>"$log_path"
    return 1
  fi
  return 0
}

# Execute one event file. Returns 0 always (failure recorded in run meta).
run_event() {
  local event_path="$1"
  local project kind ref sha pr_id base source
  project="$(event_field "$event_path" project)"
  kind="$(event_field "$event_path" kind)"
  ref="$(event_field "$event_path" ref)"
  sha="$(event_field "$event_path" sha)"
  pr_id="$(event_field "$event_path" pr_id)"
  [[ "$pr_id" == "null" ]] && pr_id=
  base="$(event_field "$event_path" base)"
  [[ "$base" == "null" ]] && base=
  source="$(event_field "$event_path" source)"
  [[ -z "$source" || "$source" == "null" ]] && source=poll

  local pfile
  pfile="$(_find_project_file_by_name "$project")" || {
    warn "no project conf for $project, dropping event"
    event_mark_done "$event_path"
    return 0
  }
  load_project_file "$pfile"
  validate_project || {
    event_mark_done "$event_path"
    return 0
  }

  local lockdir="$DATA_DIR/state/${NAME}.lockdir"
  mkdir -p "$(dirname "$lockdir")"
  if ! lock_acquire "$lockdir"; then
    info "project $NAME busy/lock timeout, leave event pending"
    return 0
  fi
  # shellcheck disable=SC2064
  trap "_clone_cleanup; lock_release '$lockdir'" RETURN

  # ponytail: only current head; stale SHA must not run or regress state
  local tracked state_kind state_key
  if [[ "$kind" == "pr" && -n "$pr_id" ]]; then
    state_kind=pr
    state_key="$pr_id"
  else
    state_kind=branch
    state_key="$ref"
  fi
  tracked="$(state_get_sha "$state_kind" "$state_key")"
  if [[ -n "$tracked" && "$tracked" != "$sha" ]]; then
    info "skip stale event project=$NAME $state_kind=$state_key sha=${sha:0:8} tracked=${tracked:0:8}"
    event_mark_done "$event_path"
    return 0
  fi

  # success sticky already covers this sha → record skipped, no clone (manual always runs)
  if [[ "$kind" == "pr" && -n "$pr_id" && "$source" != "manual" ]] \
    && report_pr_should_skip_run "$pr_id" "$sha"; then
    local run_id start_epoch end_epoch log_path meta
    run_id="$(make_id)"
    start_epoch="$(epoch_now)"
    end_epoch="$start_epoch"
    log_path="$DATA_DIR/logs/$NAME/${run_id}-${sha:0:8}.log"
    mkdir -p "$(dirname "$log_path")" "$DATA_DIR/runs"
    {
      echo "=== WatchCI run $run_id ==="
      echo "project=$NAME kind=$kind ref=$ref pr_id=$pr_id source=$source sha=$sha"
      echo "started=$(iso_now)"
      echo "skipped: success PR comment matches sha=${sha:0:8}"
    } >"$log_path"
    meta="$DATA_DIR/runs/${run_id}.meta.json"
    if command -v jq >/dev/null 2>&1; then
      jq -n \
        --arg id "$run_id" \
        --arg project "$NAME" \
        --arg kind "$kind" \
        --arg ref "$ref" \
        --arg pr_id "$pr_id" \
        --arg sha "$sha" \
        --arg status "skipped" \
        --arg source "$source" \
        --argjson exit_code 0 \
        --argjson started "$start_epoch" \
        --argjson finished "$end_epoch" \
        --argjson duration 0 \
        --argjson timeout_sec "${TIMEOUT_SEC:-0}" \
        --argjson attempts 0 \
        --arg log "$log_path" \
        '{
          id:$id, project:$project, kind:$kind, ref:$ref,
          pr_id:(if $pr_id=="" then null else $pr_id end),
          sha:$sha, status:$status, source:$source, exit_code:$exit_code,
          started:$started, finished:$finished, duration:$duration,
          timeout_sec:$timeout_sec, attempts:$attempts, log:$log
        }' >"$meta"
    else
      cat >"$meta" <<EOF
{"id":"$run_id","project":"$NAME","kind":"$kind","ref":"$ref","pr_id":"$pr_id","sha":"$sha","status":"skipped","source":"$source","exit_code":0,"started":$start_epoch,"finished":$end_epoch,"duration":0,"timeout_sec":${TIMEOUT_SEC:-0},"attempts":0,"log":"$log_path"}
EOF
    fi
    tracked="$(state_get_sha "$state_kind" "$state_key")"
    if [[ -z "$tracked" || "$tracked" == "$sha" ]]; then
      state_set "$state_kind" "$state_key" "$sha" "skipped" "$run_id"
    fi
    site_update_after_run "$run_id" || warn "site update failed"
    event_mark_done "$event_path"
    info "skip pr run $run_id project=$NAME pr=$pr_id sha=${sha:0:8} (success comment)"
    return 0
  fi

  ensure_clone
  local run_id start_epoch end_epoch exit_code status
  run_id="$(make_id)"
  local log_path="$DATA_DIR/logs/$NAME/${run_id}-${sha:0:8}.log"
  mkdir -p "$(dirname "$log_path")"

  info "run $run_id project=$NAME kind=$kind ref=$ref source=$source sha=${sha:0:8}"
  start_epoch="$(epoch_now)"
  exit_code=0
  local attempts=0

  {
    echo "=== WatchCI run $run_id ==="
    echo "project=$NAME kind=$kind ref=$ref pr_id=${pr_id:-} source=$source sha=$sha"
    echo "started=$(iso_now)"
    echo "timeout_sec=$TIMEOUT_SEC"
    echo "fail_retries=$FAIL_RETRIES"
    echo "=== checkout ==="
  } >"$log_path"

  if ! _checkout_sha "$sha" "$kind" "$pr_id" "$log_path" "$base"; then
    exit_code=1
  else
    local script_path cwd
    # daily may use DAILY_SCRIPT; empty → fall back to SCRIPT
    if [[ "$source" == "daily" && -n "${DAILY_SCRIPT:-}" ]]; then
      SCRIPT="$DAILY_SCRIPT"
    fi
    _SCRIPT_CMDLINE=()
    if ! _script_cmdline; then
      echo "SCRIPT empty/invalid: ${SCRIPT:-}" >>"$log_path"
      exit_code=127
    else
      script_path="${_SCRIPT_CMDLINE[0]}"
      cwd="$CLONE_DIR"
      if [[ -n "${WORKDIR:-}" ]]; then
        if [[ "$WORKDIR" = /* ]]; then
          cwd="$WORKDIR"
        else
          cwd="$CLONE_DIR/$WORKDIR"
        fi
      fi
      {
        echo "=== script ${_SCRIPT_CMDLINE[*]} (cwd=$cwd timeout_sec=$TIMEOUT_SEC) ==="
      } >>"$log_path"
      if [[ ! -f "$script_path" ]]; then
        echo "script not found: $script_path" >>"$log_path"
        exit_code=127
      else
        chmod +x "$script_path" 2>/dev/null || true
        # duration / timeout apply to script only (not clone/checkout)
        start_epoch="$(epoch_now)"
        while true; do
          set +e
          (
            cd "$cwd" || exit 1
            export WATCHCI_SHA="$sha"
            export WATCHCI_REF="$ref"
            export WATCHCI_KIND="$kind"
            export WATCHCI_PR_ID="${pr_id:-}"
            export WATCHCI_PROJECT="$NAME"
            export WATCHCI_LOG="$log_path"
            export WATCHCI_RUN_ID="$run_id"
            export WATCHCI_TIMEOUT_SEC="$TIMEOUT_SEC"
            export WATCHCI_SOURCE="$source"
            run_with_timeout "$TIMEOUT_SEC" bash "${_SCRIPT_CMDLINE[@]}"
          ) >>"$log_path" 2>&1
          exit_code=$?
          set -e
          attempts=$((attempts + 1))
          [[ "$exit_code" -eq 0 ]] && break
          # attempts-1 == completed failures so far; FAIL_RETRIES = extra tries allowed
          [[ "$((attempts - 1))" -ge "$FAIL_RETRIES" ]] && break
          echo "=== retry $attempts/$FAIL_RETRIES after exit=$exit_code ===" >>"$log_path"
          _clone_cleanup
          if ! _checkout_sha "$sha" "$kind" "$pr_id" "$log_path" "$base"; then
            exit_code=1
            break
          fi
        done
      fi
    fi
  fi

  end_epoch="$(epoch_now)"
  local duration=$((end_epoch - start_epoch))
  if [[ "$exit_code" -eq 0 ]]; then
    status=success
  elif [[ "$exit_code" -eq 124 ]]; then
    status=timeout
  else
    status=failure
  fi
  echo "=== finished status=$status exit=$exit_code duration=${duration}s timeout_sec=$TIMEOUT_SEC attempts=$attempts ===" >>"$log_path"

  # Write run meta JSON
  local meta="$DATA_DIR/runs/${run_id}.meta.json"
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg id "$run_id" \
      --arg project "$NAME" \
      --arg kind "$kind" \
      --arg ref "$ref" \
      --arg pr_id "${pr_id:-}" \
      --arg sha "$sha" \
      --arg status "$status" \
      --arg source "$source" \
      --argjson exit_code "$exit_code" \
      --argjson started "$start_epoch" \
      --argjson finished "$end_epoch" \
      --argjson duration "$duration" \
      --argjson timeout_sec "$TIMEOUT_SEC" \
      --argjson attempts "$attempts" \
      --arg log "$log_path" \
      '{
        id:$id, project:$project, kind:$kind, ref:$ref,
        pr_id:(if $pr_id=="" then null else $pr_id end),
        sha:$sha, status:$status, source:$source, exit_code:$exit_code,
        started:$started, finished:$finished, duration:$duration,
        timeout_sec:$timeout_sec, attempts:$attempts, log:$log
      }' >"$meta"
  else
    cat >"$meta" <<EOF
{"id":"$run_id","project":"$NAME","kind":"$kind","ref":"$ref","pr_id":$( [[ -n "$pr_id" ]] && echo "\"$pr_id\"" || echo null ),"sha":"$sha","status":"$status","source":"$source","exit_code":$exit_code,"started":$start_epoch,"finished":$end_epoch,"duration":$duration,"timeout_sec":$TIMEOUT_SEC,"attempts":$attempts,"log":"$log_path"}
EOF
  fi

  # only write result if still the tracked head (poll may have moved on)
  tracked="$(state_get_sha "$state_kind" "$state_key")"
  if [[ -z "$tracked" || "$tracked" == "$sha" ]]; then
    state_set "$state_kind" "$state_key" "$sha" "$status" "$run_id"
  else
    info "skip state regress project=$NAME $state_kind=$state_key sha=${sha:0:8} tracked=${tracked:0:8}"
  fi

  site_update_after_run "$run_id" || warn "site update failed"

  if [[ -z "$tracked" || "$tracked" == "$sha" ]]; then
    report_pr_comment "$run_id" || warn "pr comment failed"
  else
    info "skip stale pr comment project=$NAME $state_kind=$state_key sha=${sha:0:8} tracked=${tracked:0:8}"
  fi

  event_mark_done "$event_path"
  info "run $run_id done status=$status duration=${duration}s timeout_sec=$TIMEOUT_SEC attempts=$attempts"
}

# Drain up to MAX_PARALLEL_RUNS events (serial if 1).
drain_events() {
  local f count=0
  while IFS= read -r f; do
    [[ -f "$f" ]] || continue
    run_event "$f"
    count=$((count + 1))
    # ponytail: serial only; MAX_PARALLEL_RUNS reserved for later
    [[ "$count" -ge "${MAX_PARALLEL_RUNS:-1}" ]] && break
  done < <(events_list_pending)
}
