#!/usr/bin/env bash
# Per-project state: last seen SHAs for branches and PRs.
# Format (TSV): kind \t key \t sha \t last_run_status \t last_run_id \t updated_at

state_file() {
  local name="${1:-$NAME}"
  echo "$DATA_DIR/state/${name}.tsv"
}

state_ensure() {
  local sf
  sf="$(state_file "${1:-$NAME}")"
  mkdir -p "$(dirname "$sf")"
  [[ -f "$sf" ]] || : >"$sf"
}

# Get stored sha for kind+key. kind=branch|pr, key=branch name or pr id.
state_get_sha() {
  local kind="$1" key="$2"
  local sf
  sf="$(state_file)"
  state_ensure
  while IFS=$'\t' read -r r_kind r_key r_sha r_status r_run r_ts; do
    [[ "$r_kind" == "$kind" && "$r_key" == "$key" ]] && { echo "$r_sha"; return 0; }
  done <"$sf"
  return 0
}

# Upsert state row.
state_set() {
  local kind="$1" key="$2" sha="$3" status="${4:-}" run_id="${5:-}"
  local sf tmp ts
  sf="$(state_file)"
  state_ensure
  ts="$(iso_now)"
  tmp="$(mktemp)"
  local found=0
  while IFS=$'\t' read -r r_kind r_key r_sha r_status r_run r_ts || [[ -n "${r_kind:-}" ]]; do
    [[ -z "${r_kind:-}" ]] && continue
    if [[ "$r_kind" == "$kind" && "$r_key" == "$key" ]]; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$key" "$sha" "${status:-$r_status}" "${run_id:-$r_run}" "$ts"
      found=1
    else
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$r_kind" "$r_key" "$r_sha" "$r_status" "$r_run" "$r_ts"
    fi
  done <"$sf" >"$tmp"
  if [[ "$found" -eq 0 ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$key" "$sha" "$status" "$run_id" "$ts" >>"$tmp"
  fi
  mv -f "$tmp" "$sf"
}
