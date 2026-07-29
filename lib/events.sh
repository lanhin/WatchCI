#!/usr/bin/env bash
# Event queue: pending JSON files.

events_pending_dir() { echo "$DATA_DIR/events/pending"; }
events_done_dir() { echo "$DATA_DIR/events/done"; }

# Drop pending for same PR/branch key but different sha (newer head wins).
event_drop_stale_pending() {
  local project="$1" kind="$2" ref="$3" sha="$4" pr_id="${5:-}"
  local f f_project f_kind f_ref f_sha f_pr
  mkdir -p "$(events_pending_dir)"
  for f in "$(events_pending_dir)"/*.json; do
    [[ -f "$f" ]] || continue
    f_project="$(event_field "$f" project)"
    [[ "$f_project" == "$project" ]] || continue
    f_kind="$(event_field "$f" kind)"
    [[ "$f_kind" == "$kind" ]] || continue
    f_sha="$(event_field "$f" sha)"
    [[ -n "$f_sha" && "$f_sha" != "$sha" ]] || continue
    if [[ "$kind" == "pr" ]]; then
      f_pr="$(event_field "$f" pr_id)"
      [[ "$f_pr" == "null" ]] && f_pr=
      [[ "$f_pr" == "$pr_id" ]] || continue
    else
      f_ref="$(event_field "$f" ref)"
      [[ "$f_ref" == "$ref" ]] || continue
    fi
    info "drop stale pending $(basename "$f") sha=${f_sha:0:8} keep=${sha:0:8}"
    event_mark_done "$f"
  done
}

# Enqueue event. Args: project kind ref sha [pr_id] [source] [base]
event_enqueue() {
  local project="$1" kind="$2" ref="$3" sha="$4"
  local pr_id="${5:-}"
  local source="${6:-poll}"
  local base="${7:-}"
  local id path
  id="$(make_id)"
  path="$(events_pending_dir)/${id}.json"
  mkdir -p "$(events_pending_dir)"
  event_drop_stale_pending "$project" "$kind" "$ref" "$sha" "$pr_id"
  # Dedup: skip if pending already has same project+kind+ref+sha
  local f
  for f in "$(events_pending_dir)"/*.json; do
    [[ -f "$f" ]] || continue
    if grep -q "\"project\": \"$project\"" "$f" \
      && grep -q "\"kind\": \"$kind\"" "$f" \
      && grep -q "\"ref\": \"$ref\"" "$f" \
      && grep -q "\"sha\": \"$sha\"" "$f"; then
      return 0
    fi
  done
  if command -v jq >/dev/null 2>&1; then
    jq -n \
      --arg project "$project" \
      --arg kind "$kind" \
      --arg ref "$ref" \
      --arg sha "$sha" \
      --arg pr_id "$pr_id" \
      --arg source "$source" \
      --arg base "$base" \
      --argjson ts "$(epoch_now)" \
      '{project:$project, kind:$kind, ref:$ref, pr_id:(if $pr_id=="" then null else $pr_id end), sha:$sha, source:$source, base:(if $base=="" then null else $base end), ts:$ts}' \
      >"$path"
  else
    cat >"$path" <<EOF
{"project": "$project", "kind": "$kind", "ref": "$ref", "pr_id": $( [[ -n "$pr_id" ]] && echo "\"$pr_id\"" || echo null ), "sha": "$sha", "source": "$source", "base": $( [[ -n "$base" ]] && echo "\"$base\"" || echo null ), "ts": $(epoch_now)}
EOF
  fi
  info "enqueued event $id project=$project kind=$kind ref=$ref sha=${sha:0:8}"
}

# List pending event files sorted by name (roughly time order).
events_list_pending() {
  local f
  for f in "$(events_pending_dir)"/*.json; do
    [[ -f "$f" ]] || continue
    echo "$f"
  done | sort
}

event_mark_done() {
  local path="$1"
  [[ -f "$path" ]] || return 0
  mkdir -p "$(events_done_dir)"
  mv -f "$path" "$(events_done_dir)/$(basename "$path")"
}

# Read field from event JSON (best-effort without jq for common fields).
event_field() {
  local path="$1" field="$2"
  if command -v jq >/dev/null 2>&1; then
    jq -r --arg f "$field" '.[$f] // empty' "$path"
  else
    # crude: "field": "value" or "field": null
    sed -n "s/.*\"$field\": *\"\\([^\"]*\\)\".*/\\1/p;s/.*\"$field\": *null.*/null/p" "$path" | head -1
  fi
}
