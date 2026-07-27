#!/usr/bin/env bash
# Load and validate WatchCI configs.

# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"

CONFIG_DIR="${CONFIG_DIR:-$WATCHCI_ROOT/config}"
GLOBAL_CONF="${GLOBAL_CONF:-$CONFIG_DIR/watchci.conf}"
PROJECTS_DIR="${PROJECTS_DIR:-$CONFIG_DIR/projects}"

# Defaults applied after sourcing global conf.
_apply_global_defaults() {
  DATA_DIR="${DATA_DIR:-$WATCHCI_ROOT/data}"
  [[ "$DATA_DIR" = /* ]] || DATA_DIR="$WATCHCI_ROOT/$DATA_DIR"
  POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-60}"
  MAX_PARALLEL_RUNS="${MAX_PARALLEL_RUNS:-1}"
  DEFAULT_TIMEOUT_SEC="${DEFAULT_TIMEOUT_SEC:-1800}"
  SITE_DIR="${SITE_DIR:-$DATA_DIR/site}"
  [[ "$SITE_DIR" = /* ]] || SITE_DIR="$WATCHCI_ROOT/$SITE_DIR"
  PUBLISH_CMD="${PUBLISH_CMD:-}"
  AUTO_PUBLISH="${AUTO_PUBLISH:-false}"
  PID_FILE="${PID_FILE:-$DATA_DIR/watchci.pid}"
  LOG_FILE="${LOG_FILE:-$DATA_DIR/watchci.log}"
  ADMIN_PID_FILE="${ADMIN_PID_FILE:-$DATA_DIR/watchci-admin.pid}"
  ADMIN_BIND="${ADMIN_BIND:-127.0.0.1}"
  ADMIN_PORT="${ADMIN_PORT:-8787}"
  ADMIN_TOKEN="${ADMIN_TOKEN:-}"
  ADMIN_ENABLE="${ADMIN_ENABLE:-true}"
  export DATA_DIR POLL_INTERVAL_SEC MAX_PARALLEL_RUNS DEFAULT_TIMEOUT_SEC
  export SITE_DIR PUBLISH_CMD AUTO_PUBLISH
  export PID_FILE LOG_FILE ADMIN_PID_FILE
  export ADMIN_BIND ADMIN_PORT ADMIN_TOKEN ADMIN_ENABLE
}

load_global_config() {
  if [[ ! -f "$GLOBAL_CONF" ]]; then
    if [[ -f "$CONFIG_DIR/watchci.conf.example" ]]; then
      cp "$CONFIG_DIR/watchci.conf.example" "$GLOBAL_CONF"
      info "created $GLOBAL_CONF from example"
    else
      die "missing global config: $GLOBAL_CONF"
    fi
  fi
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$GLOBAL_CONF"
  set +a
  _apply_global_defaults
  ensure_dirs
}

# List project conf files (absolute paths), skipping example if ENABLED=false and no real use — we still list all *.conf.
list_project_files() {
  local f
  [[ -d "$PROJECTS_DIR" ]] || return 0
  for f in "$PROJECTS_DIR"/*.conf; do
    [[ -f "$f" ]] || continue
    echo "$f"
  done
}

# Load one project file into current shell (caller should use subshell or reset).
# Sets PROJECT_CONF_FILE.
load_project_file() {
  local file="$1"
  [[ -f "$file" ]] || die "project conf not found: $file"
  # Reset known keys so stale values don't leak between projects.
  NAME= PROVIDER= REPO_URL= API_BASE= OWNER= REPO= BRANCHES=
  WATCH_PRS=true PR_LABELS= SCRIPT= WORKDIR= TIMEOUT_SEC=
  TOKEN_ENV= CLONE_DIR= ENABLED=true PROJECT_ID=
  unset POLL_INTERVAL_SEC 2>/dev/null || true
  # Re-apply global poll after unset — keep global as fallback via PROJECT_POLL later.
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$file"
  set +a
  PROJECT_CONF_FILE="$file"
  NAME="${NAME:-$(basename "$file" .conf)}"
  PROVIDER="${PROVIDER:-github}"
  WATCH_PRS="${WATCH_PRS:-true}"
  ENABLED="${ENABLED:-true}"
  TIMEOUT_SEC="${TIMEOUT_SEC:-$DEFAULT_TIMEOUT_SEC}"
  if [[ -z "${CLONE_DIR:-}" ]]; then
    CLONE_DIR="$DATA_DIR/clones/$NAME"
  elif [[ "$CLONE_DIR" != /* ]]; then
    CLONE_DIR="$WATCHCI_ROOT/$CLONE_DIR"
  fi
  PROJECT_POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-}"
  # Restore global POLL_INTERVAL_SEC after project may have overridden it.
  # shellcheck disable=SC1090
  POLL_INTERVAL_SEC="$(grep -E '^POLL_INTERVAL_SEC=' "$GLOBAL_CONF" 2>/dev/null | tail -1 | cut -d= -f2- || true)"
  POLL_INTERVAL_SEC="${POLL_INTERVAL_SEC:-60}"
  export NAME PROVIDER REPO_URL API_BASE OWNER REPO BRANCHES WATCH_PRS PR_LABELS
  export SCRIPT WORKDIR TIMEOUT_SEC TOKEN_ENV CLONE_DIR ENABLED PROJECT_ID
  export PROJECT_CONF_FILE PROJECT_POLL_INTERVAL_SEC
}

validate_project() {
  [[ "$ENABLED" == "true" || "$ENABLED" == "1" ]] || return 1
  [[ -n "$REPO_URL" ]] || { warn "project $NAME: REPO_URL empty, skip"; return 1; }
  [[ -n "$SCRIPT" ]] || { warn "project $NAME: SCRIPT empty, skip"; return 1; }
  case "$PROVIDER" in
    github|gitee|gitlab|gitcode) ;;
    *) warn "project $NAME: unknown PROVIDER=$PROVIDER"; return 1 ;;
  esac
  return 0
}

# Emit NAME for each enabled project (one per line).
list_enabled_projects() {
  local f
  while IFS= read -r f; do
    (
      load_project_file "$f"
      validate_project || exit 0
      echo "$NAME"
    )
  done < <(list_project_files)
}
