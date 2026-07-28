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
assert any(f["key"] == "ALLOW_MANUAL_RERUN" for f in mod.PROJECT_SCHEMA)
out = mod.dump_conf({"NAME": "x", "ENABLED": "true"}, mod.PROJECT_SCHEMA)
assert "项目名称" in out or "NAME=x" in out
assert "# " in out
print("config parse ok")

# Live floor: unfinished log detection (used by /api/live)
_logs = Path("$SMOKE_DATA/logs/smoke")
_logs.mkdir(parents=True, exist_ok=True)
_live = _logs / "999-test-deadbeef.log"
_live.write_text("=== WatchCI run ===\nrunning...\n", encoding="utf-8")
_app = mod.App(Path("$ROOT"), "", Path("$SMOKE_DATA/watchci.pid"))
assert not _app._log_finished(_live)
_live.write_text(_live.read_text(encoding="utf-8") + "=== finished status=success exit=0 ===\n", encoding="utf-8")
assert _app._log_finished(_live)
try:
    _app.tail_run_log("bad/name", "x.log", 0)
    raise SystemExit("FAIL: path reject")
except ValueError:
    pass
print("live log detect ok")
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

# provider_api_get: on 502, log redacted command (no token leak)
fakebin="$TMP/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/curl" <<'EOF'
#!/bin/sh
echo "curl: (22) The requested URL returned error: 502" >&2
exit 22
EOF
chmod +x "$fakebin/curl"
out="$(
  PATH="$fakebin:$PATH" bash -c '
    source "'"$ROOT"'/lib/common.sh"
    source "'"$ROOT"'/adapters/_interface.sh"
    provider_api_get -H "Authorization: Bearer super-secret" \
      "https://example.com/x?access_token=also-secret" >/dev/null
  ' 2>&1 || true
)"
echo "$out" | grep -q 'curl 502 command:' || { echo "FAIL: no 502 command log"; echo "$out"; exit 1; }
echo "$out" | grep -q 'Bearer' || { echo "FAIL: missing Bearer in cmd log"; echo "$out"; exit 1; }
echo "$out" | grep -q 'access_token=' || { echo "FAIL: missing access_token in cmd log"; echo "$out"; exit 1; }
if echo "$out" | grep -q 'super-secret'; then
  echo "FAIL: token leaked"; echo "$out"; exit 1
fi
if echo "$out" | grep -q 'also-secret'; then
  echo "FAIL: access_token leaked"; echo "$out"; exit 1
fi
echo "provider_api_get 502 log ok"

# Manual rerun: list / gate / enqueue / dedup (App against smoke TMP root)
python3 - <<PY
from pathlib import Path
import json
import importlib.util

spec = importlib.util.spec_from_file_location("config_admin", "$ROOT/lib/config_admin.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

root = Path("$TMP")
data = Path("$SMOKE_DATA")
runs = data / "runs"
runs.mkdir(parents=True, exist_ok=True)
pending = data / "events" / "pending"
if pending.is_dir():
    for f in pending.glob("*.json"):
        f.unlink()

fail_id = "smoke-fail-rerun-1"
sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
meta = {
    "id": fail_id,
    "project": "smoke",
    "kind": "branch",
    "ref": "main",
    "pr_id": None,
    "sha": sha,
    "status": "failure",
    "exit_code": 1,
    "started": 1,
    "finished": 2,
    "duration": 1,
    "log": "",
}
(runs / f"{fail_id}.meta.json").write_text(json.dumps(meta), encoding="utf-8")
# success should not appear in default list
ok_id = "smoke-ok-hide"
(runs / f"{ok_id}.meta.json").write_text(
    json.dumps({**meta, "id": ok_id, "status": "success", "exit_code": 0}),
    encoding="utf-8",
)

app = mod.App(root, "", data / "watchci.pid")
listed = app.list_runs()
ids = {r["id"] for r in listed}
assert fail_id in ids, listed
assert ok_id not in ids, listed

r1 = app.rerun_run(fail_id)
assert r1.get("ok") and r1.get("event_id"), r1
pend = list(pending.glob("*.json"))
assert len(pend) == 1, pend
ev = json.loads(pend[0].read_text(encoding="utf-8"))
assert ev["sha"] == sha and ev["source"] == "manual" and ev["project"] == "smoke"
# failure record removed after enqueue — no repeated rerun from the same meta
assert not (runs / f"{fail_id}.meta.json").is_file()
assert fail_id not in {r["id"] for r in app.list_runs()}

# dedup + clear siblings: same sha pending; extras for same checkout also deleted
fail_id2 = "smoke-fail-rerun-2"
fail_id2b = "smoke-fail-rerun-2b"
(runs / f"{fail_id2}.meta.json").write_text(
    json.dumps({**meta, "id": fail_id2}), encoding="utf-8"
)
(runs / f"{fail_id2b}.meta.json").write_text(
    json.dumps({**meta, "id": fail_id2b}), encoding="utf-8"
)
r2 = app.rerun_run(fail_id2)
assert r2.get("skipped") == "already_pending", r2
assert not (runs / f"{fail_id2}.meta.json").is_file()
assert not (runs / f"{fail_id2b}.meta.json").is_file()

# gate: ALLOW_MANUAL_RERUN=false
conf = Path("$TMP/config/projects/smoke.conf")
text = conf.read_text(encoding="utf-8")
if "ALLOW_MANUAL_RERUN=" in text:
    conf.write_text(
        "\n".join(
            ("ALLOW_MANUAL_RERUN=false" if line.startswith("ALLOW_MANUAL_RERUN=") else line)
            for line in text.splitlines()
        )
        + "\n",
        encoding="utf-8",
    )
else:
    conf.write_text(text.rstrip() + "\nALLOW_MANUAL_RERUN=false\n", encoding="utf-8")
# clear pending so gate is what we hit (not dedup)
for f in pending.glob("*.json"):
    f.unlink()
fail_id3 = "smoke-fail-rerun-3"
(runs / f"{fail_id3}.meta.json").write_text(
    json.dumps({**meta, "id": fail_id3}), encoding="utf-8"
)
try:
    app.rerun_run(fail_id3)
    raise SystemExit("FAIL: expected PermissionError when ALLOW_MANUAL_RERUN=false")
except PermissionError:
    pass
assert (runs / f"{fail_id3}.meta.json").is_file(), "gate fail must keep record"
print("manual rerun ok")
PY

echo "SMOKE OK"
