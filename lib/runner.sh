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

# Execute one event file. Returns 0 always (failure recorded in run meta).
run_event() {
  local event_path="$1"
  local project kind ref sha pr_id
  project="$(event_field "$event_path" project)"
  kind="$(event_field "$event_path" kind)"
  ref="$(event_field "$event_path" ref)"
  sha="$(event_field "$event_path" sha)"
  pr_id="$(event_field "$event_path" pr_id)"
  [[ "$pr_id" == "null" ]] && pr_id=

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
  trap "lock_release '$lockdir'" RETURN

  ensure_clone
  local run_id start_epoch end_epoch exit_code status
  run_id="$(make_id)"
  local log_path="$DATA_DIR/logs/$NAME/${run_id}-${sha:0:8}.log"
  mkdir -p "$(dirname "$log_path")"

  info "run $run_id project=$NAME kind=$kind ref=$ref sha=${sha:0:8}"
  start_epoch="$(epoch_now)"
  exit_code=0

  {
    echo "=== WatchCI run $run_id ==="
    echo "project=$NAME kind=$kind ref=$ref pr_id=${pr_id:-} sha=$sha"
    echo "started=$(iso_now)"
    echo "=== checkout ==="
  } >"$log_path"

  if ! git -C "$CLONE_DIR" fetch --prune origin >>"$log_path" 2>&1; then
    echo "fetch failed" >>"$log_path"
    exit_code=1
  elif ! git -C "$CLONE_DIR" checkout --detach "$sha" >>"$log_path" 2>&1; then
    echo "checkout failed" >>"$log_path"
    exit_code=1
  else
    local script_path cwd
    script_path="$(_resolve_script "$SCRIPT")"
    cwd="$CLONE_DIR"
    if [[ -n "${WORKDIR:-}" ]]; then
      if [[ "$WORKDIR" = /* ]]; then
        cwd="$WORKDIR"
      else
        cwd="$CLONE_DIR/$WORKDIR"
      fi
    fi
    {
      echo "=== script $script_path (cwd=$cwd) ==="
    } >>"$log_path"
    if [[ ! -f "$script_path" ]]; then
      echo "script not found: $script_path" >>"$log_path"
      exit_code=127
    else
      chmod +x "$script_path" 2>/dev/null || true
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
        run_with_timeout "$TIMEOUT_SEC" bash "$script_path"
      ) >>"$log_path" 2>&1
      exit_code=$?
      set -e
    fi
  fi

  end_epoch="$(epoch_now)"
  if [[ "$exit_code" -eq 0 ]]; then
    status=success
  elif [[ "$exit_code" -eq 124 ]]; then
    status=timeout
  else
    status=failure
  fi
  echo "=== finished status=$status exit=$exit_code ===" >>"$log_path"

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
      --argjson exit_code "$exit_code" \
      --argjson started "$start_epoch" \
      --argjson finished "$end_epoch" \
      --argjson duration $((end_epoch - start_epoch)) \
      --arg log "$log_path" \
      '{
        id:$id, project:$project, kind:$kind, ref:$ref,
        pr_id:(if $pr_id=="" then null else $pr_id end),
        sha:$sha, status:$status, exit_code:$exit_code,
        started:$started, finished:$finished, duration:$duration, log:$log
      }' >"$meta"
  else
    cat >"$meta" <<EOF
{"id":"$run_id","project":"$NAME","kind":"$kind","ref":"$ref","pr_id":$( [[ -n "$pr_id" ]] && echo "\"$pr_id\"" || echo null ),"sha":"$sha","status":"$status","exit_code":$exit_code,"started":$start_epoch,"finished":$end_epoch,"duration":$((end_epoch - start_epoch)),"log":"$log_path"}
EOF
  fi

  if [[ "$kind" == "pr" && -n "$pr_id" ]]; then
    state_set pr "$pr_id" "$sha" "$status" "$run_id"
  else
    state_set branch "$ref" "$sha" "$status" "$run_id"
  fi

  site_update_after_run "$run_id" || warn "site update failed"

  event_mark_done "$event_path"
  info "run $run_id done status=$status"
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
