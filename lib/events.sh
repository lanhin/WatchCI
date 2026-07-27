#!/usr/bin/env bash
# Event queue: pending JSON files.

events_pending_dir() { echo "$DATA_DIR/events/pending"; }
events_done_dir() { echo "$DATA_DIR/events/done"; }

# Enqueue event. Args: project kind ref sha [pr_id] [source]
event_enqueue() {
  local project="$1" kind="$2" ref="$3" sha="$4"
  local pr_id="${5:-}"
  local source="${6:-poll}"
  local id path
  id="$(make_id)"
  path="$(events_pending_dir)/${id}.json"
  mkdir -p "$(events_pending_dir)"
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
      --argjson ts "$(epoch_now)" \
      '{project:$project, kind:$kind, ref:$ref, pr_id:(if $pr_id=="" then null else $pr_id end), sha:$sha, source:$source, ts:$ts}' \
      >"$path"
  else
    cat >"$path" <<EOF
{"project": "$project", "kind": "$kind", "ref": "$ref", "pr_id": $( [[ -n "$pr_id" ]] && echo "\"$pr_id\"" || echo null ), "sha": "$sha", "source": "$source", "ts": $(epoch_now)}
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
