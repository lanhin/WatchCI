#!/usr/bin/env bash
# Daemon loop: poll → drain → sleep; pending / SIGHUP / reload.request wake early.

WATCHCI_RELOAD=0
WATCHCI_STOP=0

_on_hup() { WATCHCI_RELOAD=1; }
_on_term() { WATCHCI_STOP=1; }

daemon_write_pid() {
  mkdir -p "$(dirname "$PID_FILE")"
  echo $$ >"$PID_FILE"
}

daemon_clear_pid() {
  [[ -f "$PID_FILE" ]] && rm -f "$PID_FILE"
}

daemon_is_running() {
  local pid
  [[ -f "$PID_FILE" ]] || return 1
  pid="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ -n "$pid" ]] || return 1
  kill -0 "$pid" 2>/dev/null
}

daemon_request_reload() {
  # Used by config admin when PID known
  if daemon_is_running; then
    kill -HUP "$(cat "$PID_FILE")" 2>/dev/null || true
  fi
  mkdir -p "$DATA_DIR"
  date +%s >"$DATA_DIR/reload.request"
}

_maybe_reload() {
  if [[ "$WATCHCI_RELOAD" -eq 1 ]] || [[ -f "$DATA_DIR/reload.request" ]]; then
    WATCHCI_RELOAD=0
    rm -f "$DATA_DIR/reload.request"
    info "reloading config"
    load_global_config
  fi
}

_source_runtime() {
  : "${WATCHCI_ROOT:=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
  # shellcheck source=config.sh
  source "$WATCHCI_ROOT/lib/config.sh"
  # shellcheck source=state.sh
  source "$WATCHCI_ROOT/lib/state.sh"
  # shellcheck source=events.sh
  source "$WATCHCI_ROOT/lib/events.sh"
  # shellcheck source=poll.sh
  source "$WATCHCI_ROOT/lib/poll.sh"
  # shellcheck source=site.sh
  source "$WATCHCI_ROOT/lib/site.sh"
  # shellcheck source=runner.sh
  source "$WATCHCI_ROOT/lib/runner.sh"
}

daemon_tick() {
  _source_runtime
  load_global_config
  info "tick start interval=${POLL_INTERVAL_SEC}s"
  echo "$(epoch_now)" >"$DATA_DIR/last_tick"
  poll_all
  drain_events
  # drain remaining within same tick (serial)
  local n=0
  while [[ -n "$(events_list_pending | head -1)" ]]; do
    drain_events
    n=$((n + 1))
    [[ "$n" -gt 50 ]] && break
  done
  info "tick done"
}

daemon_start_admin_if_enabled() {
  [[ "${ADMIN_ENABLE}" == "true" || "${ADMIN_ENABLE}" == "1" ]] || {
    info "admin UI disabled (ADMIN_ENABLE=${ADMIN_ENABLE:-})"
    return 0
  }
  if [[ -f "$ADMIN_PID_FILE" ]] && kill -0 "$(cat "$ADMIN_PID_FILE" 2>/dev/null || true)" 2>/dev/null; then
    info "admin UI already running pid=$(cat "$ADMIN_PID_FILE") http://${ADMIN_BIND}:${ADMIN_PORT}/"
    return 0
  fi
  info "starting admin UI on ${ADMIN_BIND}:${ADMIN_PORT}"
  mkdir -p "$(dirname "$ADMIN_PID_FILE")" "$(dirname "${LOG_FILE}.admin")"
  : >>"${LOG_FILE}.admin"
  nohup python3 "$WATCHCI_ROOT/lib/config_admin.py" \
    --root "$WATCHCI_ROOT" \
    --bind "$ADMIN_BIND" \
    --port "$ADMIN_PORT" \
    --token "${ADMIN_TOKEN:-}" \
    --pid-file "$ADMIN_PID_FILE" \
    --daemon-pid-file "$PID_FILE" \
    >>"${LOG_FILE}.admin" 2>&1 &
  local bgpid=$!
  # Provisional pid (same process as python); python may rewrite the file.
  echo "$bgpid" >"$ADMIN_PID_FILE"
  local i=0
  while [[ "$i" -lt 50 ]]; do
    if kill -0 "$bgpid" 2>/dev/null; then
      # Still alive — check port is accepting (python finished bind)
      if python3 -c "import socket;s=socket.socket();s.settimeout(0.2);s.connect(('${ADMIN_BIND}', int('${ADMIN_PORT}')));s.close()" 2>/dev/null; then
        info "admin UI ready pid=$bgpid http://${ADMIN_BIND}:${ADMIN_PORT}/"
        return 0
      fi
    else
      break
    fi
    sleep 0.1
    i=$((i + 1))
  done
  warn "admin UI failed to start; see ${LOG_FILE}.admin"
  tail -n 30 "${LOG_FILE}.admin" 2>/dev/null >&2 || true
  rm -f "$ADMIN_PID_FILE"
  # ponytail: don't abort daemon if admin UI fails
  return 0
}

daemon_stop_admin() {
  if [[ -f "$ADMIN_PID_FILE" ]]; then
    local apid
    apid="$(cat "$ADMIN_PID_FILE" 2>/dev/null || true)"
    if [[ -n "$apid" ]] && kill -0 "$apid" 2>/dev/null; then
      kill "$apid" 2>/dev/null || true
    fi
    rm -f "$ADMIN_PID_FILE"
  fi
}

daemon_loop() {
  _source_runtime
  load_global_config
  require_cmd git curl python3
  command -v jq >/dev/null 2>&1 || warn "jq not found — PR adapters need jq"
  trap _on_hup HUP
  trap _on_term TERM INT
  daemon_write_pid
  daemon_start_admin_if_enabled
  info "daemon started pid=$$ interval=${POLL_INTERVAL_SEC}s"
  while [[ "$WATCHCI_STOP" -eq 0 ]]; do
    _maybe_reload
    daemon_tick || warn "tick error"
    _maybe_reload
    local i=0
    # ponytail: 1s slices; pending (rerun/webhook) or reload wakes without waiting full interval
    while [[ "$i" -lt "$POLL_INTERVAL_SEC" && "$WATCHCI_STOP" -eq 0 && "$WATCHCI_RELOAD" -eq 0 ]]; do
      sleep 1
      i=$((i + 1))
      [[ -f "$DATA_DIR/reload.request" ]] && WATCHCI_RELOAD=1
      [[ -n "$(events_list_pending | head -1)" ]] && break
    done
  done
  info "daemon stopping"
  daemon_stop_admin
  daemon_clear_pid
}

daemon_stop() {
  _source_runtime
  load_global_config
  if ! daemon_is_running; then
    info "daemon not running"
    daemon_stop_admin
    daemon_clear_pid
    return 0
  fi
  local pid
  pid="$(cat "$PID_FILE")"
  info "sending TERM to $pid"
  kill -TERM "$pid" 2>/dev/null || true
  local i=0
  while kill -0 "$pid" 2>/dev/null && [[ "$i" -lt 30 ]]; do
    sleep 1
    i=$((i + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    warn "force kill $pid"
    kill -KILL "$pid" 2>/dev/null || true
  fi
  daemon_stop_admin
  daemon_clear_pid
}

daemon_status() {
  _source_runtime
  load_global_config
  echo "WATCHCI_ROOT=$WATCHCI_ROOT"
  echo "POLL_INTERVAL_SEC=$POLL_INTERVAL_SEC"
  echo "DATA_DIR=$DATA_DIR"
  echo "SITE_DIR=$SITE_DIR"
  if daemon_is_running; then
    echo "daemon=running pid=$(cat "$PID_FILE")"
  else
    echo "daemon=stopped"
  fi
  if [[ -f "$ADMIN_PID_FILE" ]] && kill -0 "$(cat "$ADMIN_PID_FILE")" 2>/dev/null; then
    echo "admin=running pid=$(cat "$ADMIN_PID_FILE") http://${ADMIN_BIND}:${ADMIN_PORT}/"
  else
    echo "admin=stopped"
  fi
  if [[ -f "$DATA_DIR/last_tick" ]]; then
    echo "last_tick_epoch=$(cat "$DATA_DIR/last_tick")"
  fi
}

daemon_ui_only() {
  _source_runtime
  load_global_config
  require_cmd python3
  # foreground
  exec python3 "$WATCHCI_ROOT/lib/config_admin.py" \
    --root "$WATCHCI_ROOT" \
    --bind "$ADMIN_BIND" \
    --port "$ADMIN_PORT" \
    --token "$ADMIN_TOKEN" \
    --pid-file "$ADMIN_PID_FILE" \
    --daemon-pid-file "$PID_FILE"
}
