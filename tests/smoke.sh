#!/usr/bin/env bash
# Minimal self-check: local bare repo → configure project → tick → site exists.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$ROOT/data/smoke-tmp"
rm -rf "$TMP"
mkdir -p "$TMP/remote" "$TMP/work" "$TMP/config/projects"

# Create a tiny git repo and bare remote
git -C "$TMP/work" init -q -b main
git -C "$TMP/work" config user.email "smoke@watchci.local"
git -C "$TMP/work" config user.name "WatchCI Smoke"
echo "hello" >"$TMP/work/README.md"
cp "$ROOT/scripts/ci.example.sh" "$TMP/work/run-ci.sh"
chmod +x "$TMP/work/run-ci.sh"
git -C "$TMP/work" add .
git -C "$TMP/work" commit -q -m "init"
git -C "$TMP/work" remote add origin "$TMP/remote"
git init -q --bare "$TMP/remote"
git -C "$TMP/work" push -q origin main

# Isolated config — do not touch repo config/watchci.conf
SMOKE_DATA="$TMP/data"
mkdir -p "$SMOKE_DATA"
cat >"$TMP/config/watchci.conf" <<EOF
DATA_DIR=$SMOKE_DATA
POLL_INTERVAL_SEC=60
MAX_PARALLEL_RUNS=1
DEFAULT_TIMEOUT_SEC=60
SITE_DIR=$SMOKE_DATA/site
AUTO_PUBLISH=false
ADMIN_ENABLE=false
ADMIN_BIND=127.0.0.1
ADMIN_PORT=8787
EOF

cat >"$TMP/config/projects/smoke.conf" <<EOF
NAME=smoke
PROVIDER=github
REPO_URL=$TMP/remote
OWNER=local
REPO=smoke
BRANCHES=main
WATCH_PRS=false
SCRIPT=./run-ci.sh
ENABLED=true
TIMEOUT_SEC=60
EOF

export CONFIG_DIR="$TMP/config"
export GLOBAL_CONF="$TMP/config/watchci.conf"
export PROJECTS_DIR="$TMP/config/projects"

# First tick: clone + detect branch + run
"$ROOT/bin/watchci" tick

# Assert run meta + site
shopt -s nullglob
metas=("$SMOKE_DATA"/runs/*.meta.json)
[[ ${#metas[@]} -ge 1 ]] || { echo "FAIL: no run meta"; exit 1; }
[[ -f "$SMOKE_DATA/site/index.html" ]] || { echo "FAIL: no index.html"; exit 1; }
[[ -f "$SMOKE_DATA/site/data/runs.json" ]] || { echo "FAIL: no runs.json"; exit 1; }

# Second commit should enqueue another run
echo "world" >>"$TMP/work/README.md"
git -C "$TMP/work" add README.md
git -C "$TMP/work" commit -q -m "update"
git -C "$TMP/work" push -q origin main
"$ROOT/bin/watchci" tick
metas2=("$SMOKE_DATA"/runs/*.meta.json)
[[ ${#metas2[@]} -ge 2 ]] || { echo "FAIL: expected second run"; exit 1; }

# Env override must win over conf (ADMIN_ENABLE=false in smoke conf)
out="$(ADMIN_ENABLE=true "$ROOT/bin/watchci" status)"
echo "$out" | grep -q 'ADMIN' || true
# status prints admin=; force a quick check via python parse + env restore unit
ADMIN_ENABLE=true bash -c '
  source "'"$ROOT"'/lib/config.sh"
  export WATCHCI_ROOT="'"$ROOT"'"
  export CONFIG_DIR="'"$TMP"'/config"
  export GLOBAL_CONF="'"$TMP"'/config/watchci.conf"
  load_global_config
  [[ "$ADMIN_ENABLE" == "true" ]] || { echo "FAIL: env ADMIN_ENABLE override lost"; exit 1; }
  echo "env override ok"
'

# Config parse round-trip via admin module
python3 - <<PY
from pathlib import Path
import importlib.util
spec = importlib.util.spec_from_file_location("config_admin", "$ROOT/lib/config_admin.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
text = Path("$TMP/config/projects/smoke.conf").read_text()
d = mod.parse_conf(text)
assert d["NAME"] == "smoke"
assert "REPO_URL" in d
assert "POLL_INTERVAL_SEC" not in [f["key"] for f in mod.PROJECT_SCHEMA]
assert any(f["key"] == "POLL_INTERVAL_SEC" for f in mod.GLOBAL_SCHEMA)
out = mod.dump_conf({"NAME": "x", "ENABLED": "true"}, mod.PROJECT_SCHEMA)
assert "项目名称" in out or "NAME=x" in out
assert "# " in out
print("config parse ok")

PY

# Stale project POLL_INTERVAL_SEC must not clobber global interval
cat >>"$TMP/config/projects/smoke.conf" <<EOF
POLL_INTERVAL_SEC=99999
EOF
bash -c '
  source "'"$ROOT"'/lib/config.sh"
  export WATCHCI_ROOT="'"$ROOT"'"
  export CONFIG_DIR="'"$TMP"'/config"
  export GLOBAL_CONF="'"$TMP"'/config/watchci.conf"
  export PROJECTS_DIR="'"$TMP"'/config/projects"
  load_global_config
  [[ "$POLL_INTERVAL_SEC" == "60" ]] || { echo "FAIL: global poll expected 60 got $POLL_INTERVAL_SEC"; exit 1; }
  load_project_file "'"$TMP"'/config/projects/smoke.conf"
  [[ "$POLL_INTERVAL_SEC" == "60" ]] || { echo "FAIL: project POLL leaked, got $POLL_INTERVAL_SEC"; exit 1; }
  echo "project poll isolation ok"
'

# webhook ingest smoke
payload='{"ref":"refs/heads/main","after":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}'
out="$(echo "$payload" | WATCHCI_PROJECT=smoke "$ROOT/hooks/webhook_ingest.sh" github push)"
echo "$out" | grep -q '"kind": "branch"' || echo "$out" | grep -q '"kind":"branch"'

# PR head lives only under refs/pull/*/head (not refs/heads/*) — must still checkout
echo "pr-only" >"$TMP/work/pr.txt"
git -C "$TMP/work" add pr.txt
git -C "$TMP/work" commit -q -m "pr-only"
PR_SHA="$(git -C "$TMP/work" rev-parse HEAD)"
git -C "$TMP/work" push -q origin "HEAD:refs/pull/1/head"
git -C "$TMP/work" reset -q --hard origin/main
# enqueue PR event without API poll
bash -c '
  source "'"$ROOT"'/lib/common.sh"
  source "'"$ROOT"'/lib/config.sh"
  source "'"$ROOT"'/lib/events.sh"
  export WATCHCI_ROOT="'"$ROOT"'"
  export CONFIG_DIR="'"$TMP"'/config"
  export GLOBAL_CONF="'"$TMP"'/config/watchci.conf"
  export PROJECTS_DIR="'"$TMP"'/config/projects"
  load_global_config
  event_enqueue smoke pr fix/pr-only "'"$PR_SHA"'" 1 smoke
'
"$ROOT/bin/watchci" tick
pr_ok=0
for m in "$SMOKE_DATA"/runs/*.meta.json; do
  if grep -q "$PR_SHA" "$m" && grep -q '"status": "success"' "$m"; then
    pr_ok=1
    break
  fi
done
[[ "$pr_ok" -eq 1 ]] || { echo "FAIL: PR-only ref checkout/run"; exit 1; }
echo "pr head fetch ok"

echo "SMOKE OK"
