#!/usr/bin/env bash
# Static site update + publish.

site_ensure_assets() {
  mkdir -p "$SITE_DIR/assets" "$SITE_DIR/data" "$SITE_DIR/runs"
  if [[ -d "$WATCHCI_ROOT/site_template/assets" ]]; then
    cp -f "$WATCHCI_ROOT/site_template/assets/"* "$SITE_DIR/assets/" 2>/dev/null || true
  fi
}

site_update_after_run() {
  local run_id="$1"
  site_ensure_assets
  python3 "$WATCHCI_ROOT/lib/render_site.py" \
    --runs-dir "$DATA_DIR/runs" \
    --site-dir "$SITE_DIR" \
    --run-id "$run_id" \
    --log-src "$DATA_DIR/logs"
  if [[ "${AUTO_PUBLISH}" == "true" || "${AUTO_PUBLISH}" == "1" ]]; then
    site_publish || warn "AUTO_PUBLISH failed"
  fi
}

site_rebuild_all() {
  site_ensure_assets
  python3 "$WATCHCI_ROOT/lib/render_site.py" \
    --runs-dir "$DATA_DIR/runs" \
    --site-dir "$SITE_DIR" \
    --log-src "$DATA_DIR/logs"
}

site_publish() {
  if [[ -z "${PUBLISH_CMD:-}" ]]; then
    warn "PUBLISH_CMD empty; nothing to publish"
    return 1
  fi
  info "publish: $PUBLISH_CMD"
  # shellcheck disable=SC2086
  (cd "$SITE_DIR" && eval "$PUBLISH_CMD")
}
