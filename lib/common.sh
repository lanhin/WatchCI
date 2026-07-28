#!/usr/bin/env bash
# Shared helpers for WatchCI.

WATCHCI_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export WATCHCI_ROOT

log() {
  local level="$1"; shift
  local ts
  ts="$(date '+%Y-%m-%d %H:%M:%S')"
  echo "[$ts] [$level] $*" >&2
  if [[ -n "${LOG_FILE:-}" ]]; then
    echo "[$ts] [$level] $*" >>"$LOG_FILE"
  fi
}

info()  { log INFO "$@"; }
warn()  { log WARN "$@"; }
error() { log ERROR "$@"; }

die() {
  error "$@"
  exit 1
}

require_cmd() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing required command: $c"
  done
}

# Atomic write via temp + mv.
atomic_write() {
  local dest="$1"
  local tmp
  tmp="$(mktemp "${dest}.XXXXXX")"
  cat >"$tmp"
  mv -f "$tmp" "$dest"
}

ensure_dirs() {
  mkdir -p \
    "$DATA_DIR/clones" \
    "$DATA_DIR/state" \
    "$DATA_DIR/events/pending" \
    "$DATA_DIR/events/done" \
    "$DATA_DIR/logs" \
    "$DATA_DIR/runs" \
    "$SITE_DIR" \
    "$SITE_DIR/data" \
    "$SITE_DIR/runs" \
    "$SITE_DIR/assets"
}

iso_now() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

epoch_now() {
  date +%s
}

# Simple uuid-ish id without external deps.
make_id() {
  echo "$(epoch_now)-$$-$RANDOM"
}

# Portable mutex (mkdir). flock may be missing on macOS.
lock_acquire() {
  local lockdir="$1"
  local i=0
  while ! mkdir "$lockdir" 2>/dev/null; do
    sleep 0.2
    i=$((i + 1))
    [[ "$i" -gt 150 ]] && return 1
  done
  return 0
}

lock_release() {
  rmdir "$1" 2>/dev/null || true
}

# timeout(1) may be missing on macOS — fall back to background+sleep kill.
run_with_timeout() {
  local sec="$1"
  shift
  if command -v timeout >/dev/null 2>&1; then
    timeout "$sec" "$@"
    return $?
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$sec" "$@"
    return $?
  fi
  # ponytail: monitor mode → bg job gets its own pgid; kill -pgid hits ctest kids
  # ceiling: no SIGKILL escalate if kids ignore TERM (UI still trusts meta.json)
  local pid watcher ec
  set -m
  "$@" &
  pid=$!
  (
    sleep "$sec"
    kill -TERM -"$pid" 2>/dev/null || kill -TERM "$pid" 2>/dev/null || true
  ) &
  watcher=$!
  set +e
  wait "$pid"
  ec=$?
  set -e
  kill "$watcher" 2>/dev/null || true
  wait "$watcher" 2>/dev/null || true
  set +m 2>/dev/null || true
  # 143/137 often means killed by timeout → map to 124 like GNU timeout
  if [[ "$ec" -eq 143 || "$ec" -eq 137 ]]; then
    return 124
  fi
  return "$ec"
}
