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

# Keys that may be set on the CLI env and should win over conf file.
_ENV_OVERRIDE_KEYS=(
  ADMIN_ENABLE ADMIN_BIND ADMIN_PORT ADMIN_TOKEN ADMIN_PID_FILE
  POLL_INTERVAL_SEC DATA_DIR SITE_DIR PUBLISH_CMD AUTO_PUBLISH
  PID_FILE LOG_FILE MAX_PARALLEL_RUNS DEFAULT_TIMEOUT_SEC
)

_save_env_overrides() {
  local k
  for k in "${_ENV_OVERRIDE_KEYS[@]}"; do
    if [[ -n "${!k+x}" ]]; then
      printf -v "_ENV_OV_$k" '%s' "${!k}"
      printf -v "_ENV_SET_$k" '%s' 1
    else
      printf -v "_ENV_SET_$k" '%s' 0
    fi
  done
}

_restore_env_overrides() {
  local k
  for k in "${_ENV_OVERRIDE_KEYS[@]}"; do
    local set_var="_ENV_SET_$k"
    local val_var="_ENV_OV_$k"
    if [[ "${!set_var}" == "1" ]]; then
      printf -v "$k" '%s' "${!val_var}"
    fi
  done
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
  _save_env_overrides
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$GLOBAL_CONF"
  set +a
  _restore_env_overrides
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
load_project_file() {
  local file="$1"
  [[ -f "$file" ]] || die "project conf not found: $file"
  # Old project conf may still set POLL_INTERVAL_SEC; keep global interval intact.
  local _saved_poll="${POLL_INTERVAL_SEC:-60}"
  # Reset known keys so stale values don't leak between projects.
  NAME= PROVIDER= REPO_URL= API_BASE= OWNER= REPO= BRANCHES=
  WATCH_PRS=true PR_LABELS= SCRIPT= WORKDIR= TIMEOUT_SEC=
  TOKEN_ENV= CLONE_DIR= ENABLED=true PROJECT_ID= ALLOW_MANUAL_RERUN=true
  # shellcheck disable=SC1090
  set -a
  # shellcheck source=/dev/null
  source "$file"
  set +a
  POLL_INTERVAL_SEC="$_saved_poll"
  NAME="${NAME:-$(basename "$file" .conf)}"
  PROVIDER="${PROVIDER:-github}"
  WATCH_PRS="${WATCH_PRS:-true}"
  ENABLED="${ENABLED:-true}"
  ALLOW_MANUAL_RERUN="${ALLOW_MANUAL_RERUN:-true}"
  TIMEOUT_SEC="${TIMEOUT_SEC:-$DEFAULT_TIMEOUT_SEC}"
  if [[ -z "${CLONE_DIR:-}" ]]; then
    CLONE_DIR="$DATA_DIR/clones/$NAME"
  elif [[ "$CLONE_DIR" != /* ]]; then
    CLONE_DIR="$WATCHCI_ROOT/$CLONE_DIR"
  fi
  export NAME PROVIDER REPO_URL API_BASE OWNER REPO BRANCHES WATCH_PRS PR_LABELS
  export SCRIPT WORKDIR TIMEOUT_SEC TOKEN_ENV CLONE_DIR ENABLED PROJECT_ID
  export ALLOW_MANUAL_RERUN POLL_INTERVAL_SEC
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
