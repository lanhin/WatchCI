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
  # reload must pick up conf changes (not re-capture exported vars as CLI overrides)
  [[ "$DEFAULT_TIMEOUT_SEC" == "60" ]] || { echo "FAIL: expected initial DEFAULT_TIMEOUT_SEC=60"; exit 1; }
  sed -i.bak "s/^DEFAULT_TIMEOUT_SEC=.*/DEFAULT_TIMEOUT_SEC=99/" "'"$TMP"'/config/watchci.conf"
  load_global_config
  [[ "$DEFAULT_TIMEOUT_SEC" == "99" ]] || { echo "FAIL: reload did not apply DEFAULT_TIMEOUT_SEC (got $DEFAULT_TIMEOUT_SEC)"; exit 1; }
  [[ "$ADMIN_ENABLE" == "true" ]] || { echo "FAIL: env override lost after reload"; exit 1; }
  # daemon_tick re-sources config.sh each loop — must not re-poison overrides
  source "'"$ROOT"'/lib/config.sh"
  sed -i.bak "s/^DEFAULT_TIMEOUT_SEC=.*/DEFAULT_TIMEOUT_SEC=100/" "'"$TMP"'/config/watchci.conf"
  load_global_config
  [[ "$DEFAULT_TIMEOUT_SEC" == "100" ]] || { echo "FAIL: after re-source, got DEFAULT_TIMEOUT_SEC=$DEFAULT_TIMEOUT_SEC want 100"; exit 1; }
  [[ "$ADMIN_ENABLE" == "true" ]] || { echo "FAIL: env override lost after re-source"; exit 1; }
  echo "env override + reload ok"
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
_app_data = Path("$SMOKE_DATA")
assert not _app._log_finished(_live, _app_data)
_live.write_text(_live.read_text(encoding="utf-8") + "=== finished status=success exit=0 ===\n", encoding="utf-8")
assert _app._log_finished(_live, _app_data)
# meta wins even when orphan stdout buries the finish mark past the tail window
_buried = _logs / "1785234105-82352-10123-8f2bb147.log"
_buried.write_text(
    "=== WatchCI run ===\n=== finished status=timeout exit=124 ===\n" + ("x" * 70000),
    encoding="utf-8",
)
(_app_data / "runs").mkdir(parents=True, exist_ok=True)
(_app_data / "runs" / "1785234105-82352-10123.meta.json").write_text(
    '{"id":"1785234105-82352-10123","status":"timeout"}\n', encoding="utf-8"
)
assert _app._log_finished(_buried, _app_data)
assert not _app._log_finished(_buried, Path("$SMOKE_DATA/missing-data"))  # no meta → tail only; mark buried
# without meta, enlarged 64KiB window still sees mark if within window
_near = _logs / "1785234105-82352-99999-aabbccdd.log"
_near.write_text(
    "=== WatchCI run ===\n=== finished status=timeout exit=124 ===\n" + ("y" * 10000),
    encoding="utf-8",
)
assert _app._log_finished(_near, Path("$SMOKE_DATA/missing-data"))
# timeout_sec header + finished duration for live UI
_to = _logs / "1785234105-timeout-ui-deadbeef.log"
_to.write_text(
    "=== WatchCI run ===\n"
    "project=smoke kind=branch ref=main pr_id= sha=abc\n"
    "started=2026-01-01T00:00:00Z\n"
    "timeout_sec=42\n"
    "=== script ./x (cwd=/tmp timeout_sec=42) ===\n"
    "=== finished status=timeout exit=124 duration=42s timeout_sec=42 ===\n",
    encoding="utf-8",
)
_hdr = _app._parse_log_header(_to)
assert _hdr.get("timeout_sec") == "42", _hdr
_fin = _app._parse_finished_line(_to)
assert _fin.get("status") == "timeout" and _fin.get("duration") == "42" and _fin.get("timeout_sec") == "42", _fin
# cleanup fixtures so later rerun list smoke is not polluted
_buried.unlink(missing_ok=True)
_near.unlink(missing_ok=True)
_to.unlink(missing_ok=True)
(_app_data / "runs" / "1785234105-82352-10123.meta.json").unlink(missing_ok=True)
_live.unlink(missing_ok=True)
print("live log detect ok")
try:
    _app.tail_run_log("bad/name", "x.log", 0)
    raise SystemExit("FAIL: path reject")
except ValueError:
    pass
print("live path reject ok")
PY

# run_with_timeout must kill and return 124
bash -c '
  source "'"$ROOT"'/lib/common.sh"
  set +e
  run_with_timeout 1 sleep 30
  ec=$?
  set -e
  [[ "$ec" -eq 124 ]] || { echo "FAIL: run_with_timeout expected 124 got $ec"; exit 1; }
  echo "run_with_timeout ok"
'

# TERM-ignoring script must still hit deadline (SIGKILL escalate + elapsed gate)
bash -c '
  source "'"$ROOT"'/lib/common.sh"
  export WATCHCI_TIMEOUT_KILL_GRACE=1
  set +e
  t0=$(date +%s)
  run_with_timeout 2 bash -c "trap \"\" TERM; sleep 30; echo should_not_print"
  ec=$?
  t1=$(date +%s)
  set -e
  [[ "$ec" -eq 124 ]] || { echo "FAIL: TERM-ignore expected 124 got $ec"; exit 1; }
  wall=$((t1 - t0))
  [[ "$wall" -lt 10 ]] || { echo "FAIL: TERM-ignore wall=${wall}s too long"; exit 1; }
  echo "run_with_timeout TERM-ignore ok (${wall}s)"
'

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

# BRANCHES filters PR by base (target), not head
bash -c '
  source "'"$ROOT"'/lib/poll.sh"
  BRANCHES=main
  branch_matches_watch main || { echo "FAIL: main should match"; exit 1; }
  branch_matches_watch develop && { echo "FAIL: develop should not match BRANCHES=main"; exit 1; }
  BRANCHES="main, release/*"
  branch_matches_watch release/1.0 || { echo "FAIL: release/1.0 should match"; exit 1; }
  branch_matches_watch feature/x && { echo "FAIL: feature/x should not match"; exit 1; }
  echo "branch_matches_watch ok"
'

# webhook: PR not targeting watched base is ignored
pr_payload='{"action":"opened","pull_request":{"number":110,"head":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","ref":"feat/x"},"base":{"ref":"develop"}}}'
out="$(echo "$pr_payload" | WATCHCI_PROJECT=smoke WATCHCI_BRANCHES=main "$ROOT/hooks/webhook_ingest.sh" github pull_request || true)"
[[ -z "$out" ]] || { echo "FAIL: PR to develop should be ignored when BRANCHES=main"; echo "$out"; exit 1; }
pr_payload_ok='{"action":"opened","pull_request":{"number":1,"head":{"sha":"cccccccccccccccccccccccccccccccccccccccc","ref":"feat/y"},"base":{"ref":"main"}}}'
out="$(echo "$pr_payload_ok" | WATCHCI_PROJECT=smoke WATCHCI_BRANCHES=main "$ROOT/hooks/webhook_ingest.sh" github pull_request)"
echo "$out" | grep -q '"kind": "pr"' || echo "$out" | grep -q '"kind":"pr"' || { echo "FAIL: PR to main should enqueue"; echo "$out"; exit 1; }
echo "$out" | grep -q '"base": "main"' || echo "$out" | grep -q '"base":"main"' || { echo "FAIL: missing base=main"; echo "$out"; exit 1; }
echo "webhook pr base filter ok"

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

# PR diverge, no conflict: main advanced with another file → merge should succeed
echo "main-ahead" >"$TMP/work/main-ahead.txt"
git -C "$TMP/work" add main-ahead.txt
git -C "$TMP/work" commit -q -m "main-ahead"
git -C "$TMP/work" push -q origin main
git -C "$TMP/work" push -q origin "$PR_SHA:refs/pull/2/head"
bash -c '
  source "'"$ROOT"'/lib/common.sh"
  source "'"$ROOT"'/lib/config.sh"
  source "'"$ROOT"'/lib/events.sh"
  export WATCHCI_ROOT="'"$ROOT"'"
  export CONFIG_DIR="'"$TMP"'/config"
  export GLOBAL_CONF="'"$TMP"'/config/watchci.conf"
  export PROJECTS_DIR="'"$TMP"'/config/projects"
  load_global_config
  event_enqueue smoke pr fix/pr-diverge "'"$PR_SHA"'" 2 smoke
'
"$ROOT/bin/watchci" tick
pr_merge_ok=0
for m in "$SMOKE_DATA"/runs/*.meta.json; do
  if grep -q '"pr_id": "2"' "$m" 2>/dev/null || grep -q '"pr_id":"2"' "$m" 2>/dev/null; then
    if grep -q '"status": "success"' "$m"; then
      pr_merge_ok=1
      break
    fi
  fi
done
[[ "$pr_merge_ok" -eq 1 ]] || { echo "FAIL: diverge-without-conflict PR should succeed"; exit 1; }
echo "pr diverge merge ok"

# PR conflict: both sides edit conflict.txt → merge must fail
git -C "$TMP/work" reset -q --hard origin/main
echo "from-pr" >"$TMP/work/conflict.txt"
git -C "$TMP/work" add conflict.txt
git -C "$TMP/work" commit -q -m "pr-conflict"
PR_CONFLICT_SHA="$(git -C "$TMP/work" rev-parse HEAD)"
git -C "$TMP/work" push -q origin "HEAD:refs/pull/3/head"
git -C "$TMP/work" reset -q --hard origin/main
echo "from-main" >"$TMP/work/conflict.txt"
git -C "$TMP/work" add conflict.txt
git -C "$TMP/work" commit -q -m "main-conflict"
git -C "$TMP/work" push -q origin main
bash -c '
  source "'"$ROOT"'/lib/common.sh"
  source "'"$ROOT"'/lib/config.sh"
  source "'"$ROOT"'/lib/events.sh"
  export WATCHCI_ROOT="'"$ROOT"'"
  export CONFIG_DIR="'"$TMP"'/config"
  export GLOBAL_CONF="'"$TMP"'/config/watchci.conf"
  export PROJECTS_DIR="'"$TMP"'/config/projects"
  load_global_config
  event_enqueue smoke pr fix/pr-conflict "'"$PR_CONFLICT_SHA"'" 3 smoke
'
"$ROOT/bin/watchci" tick
pr_conflict_fail=0
pr_conflict_log=
for m in "$SMOKE_DATA"/runs/*.meta.json; do
  if grep -q '"pr_id": "3"' "$m" 2>/dev/null || grep -q '"pr_id":"3"' "$m" 2>/dev/null; then
    if grep -q '"status": "failure"' "$m"; then
      pr_conflict_fail=1
      pr_conflict_log="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("log",""))' "$m")"
      break
    fi
  fi
done
[[ "$pr_conflict_fail" -eq 1 ]] || { echo "FAIL: conflicting PR should fail merge"; exit 1; }
grep -q 'merge failed' "$pr_conflict_log" || { echo "FAIL: missing merge failed log"; cat "$pr_conflict_log"; exit 1; }
# clone left clean detached (no conflict markers / no merge in progress)
clone_dir="$SMOKE_DATA/clones/smoke"
git -C "$clone_dir" rev-parse --verify MERGE_HEAD >/dev/null 2>&1 && { echo "FAIL: MERGE_HEAD left behind"; exit 1; }
[[ -z "$(git -C "$clone_dir" status --porcelain)" ]] || { echo "FAIL: clone dirty after conflict run"; git -C "$clone_dir" status; exit 1; }
echo "pr conflict failure + cleanup ok"

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
state_dir = data / "state"
state_dir.mkdir(parents=True, exist_ok=True)
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

# earlier ticks left state for main at real git sha — point at fixture head
(state_dir / "smoke.tsv").write_text(
    f"branch\tmain\t{sha}\tfailure\t{fail_id}\t2026-01-01T00:00:00Z\n",
    encoding="utf-8",
)

app = mod.App(root, "", data / "watchci.pid")
listed = app.list_runs()
ids = {r["id"] for r in listed}
assert fail_id in ids, listed
assert ok_id not in ids, listed

# same checkout: multiple timeout/failure metas → one list row (newest)
dup_sha = "dddddddddddddddddddddddddddddddddddddddd"
dup_old = "smoke-timeout-old"
dup_new = "smoke-timeout-new"
(runs / f"{dup_old}.meta.json").write_text(
    json.dumps(
        {**meta, "id": dup_old, "sha": dup_sha, "status": "timeout", "exit_code": 124, "finished": 10}
    ),
    encoding="utf-8",
)
(runs / f"{dup_new}.meta.json").write_text(
    json.dumps(
        {**meta, "id": dup_new, "sha": dup_sha, "status": "timeout", "exit_code": 124, "finished": 20}
    ),
    encoding="utf-8",
)
# stale sha (same branch) hidden when state points at current head
stale = "smoke-timeout-stale"
stale_sha = "cccccccccccccccccccccccccccccccccccccccc"
(runs / f"{stale}.meta.json").write_text(
    json.dumps(
        {
            **meta,
            "id": stale,
            "sha": stale_sha,
            "status": "timeout",
            "exit_code": 124,
            "finished": 15,
        }
    ),
    encoding="utf-8",
)
(state_dir / "smoke.tsv").write_text(
    f"branch\tmain\t{dup_sha}\ttimeout\t{dup_new}\t2026-01-01T00:00:00Z\n",
    encoding="utf-8",
)
listed2 = app.list_runs()
ids2 = {r["id"] for r in listed2}
assert dup_new in ids2, listed2
assert dup_old not in ids2, listed2
assert stale not in ids2, listed2
assert fail_id not in ids2, listed2  # fail_id sha != tracked head
try:
    app.rerun_run(stale)
    raise SystemExit("FAIL: expected ValueError for stale sha rerun")
except ValueError as e:
    assert "过时" in str(e), e
(runs / f"{dup_old}.meta.json").unlink()
(runs / f"{dup_new}.meta.json").unlink()
(runs / f"{stale}.meta.json").unlink()

# point state at fail_id sha so rerun is allowed
(state_dir / "smoke.tsv").write_text(
    f"branch\tmain\t{sha}\tfailure\t{fail_id}\t2026-01-01T00:00:00Z\n",
    encoding="utf-8",
)
assert fail_id in {r["id"] for r in app.list_runs()}

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

# PR: only latest head in list; stale sha rejected
pr_cur = "smoke-pr-cur"
pr_old = "smoke-pr-old"
pr_sha = "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee"
pr_old_sha = "ffffffffffffffffffffffffffffffffffffffff"
(runs / f"{pr_cur}.meta.json").write_text(
    json.dumps(
        {
            **meta,
            "id": pr_cur,
            "kind": "pr",
            "ref": "feat/x",
            "pr_id": "99",
            "sha": pr_sha,
            "status": "failure",
            "finished": 30,
        }
    ),
    encoding="utf-8",
)
(runs / f"{pr_old}.meta.json").write_text(
    json.dumps(
        {
            **meta,
            "id": pr_old,
            "kind": "pr",
            "ref": "feat/x",
            "pr_id": "99",
            "sha": pr_old_sha,
            "status": "timeout",
            "exit_code": 124,
            "finished": 25,
        }
    ),
    encoding="utf-8",
)
(state_dir / "smoke.tsv").write_text(
    f"branch\tmain\t{sha}\tfailure\t{fail_id}\t2026-01-01T00:00:00Z\n"
    f"pr\t99\t{pr_sha}\tfailure\t{pr_cur}\t2026-01-01T00:00:00Z\n",
    encoding="utf-8",
)
listed_pr = app.list_runs()
pr_ids = {r["id"] for r in listed_pr}
assert pr_cur in pr_ids and pr_old not in pr_ids, listed_pr
try:
    app.rerun_run(pr_old)
    raise SystemExit("FAIL: expected ValueError for stale PR sha")
except ValueError as e:
    assert "过时" in str(e), e
(runs / f"{pr_cur}.meta.json").unlink()
(runs / f"{pr_old}.meta.json").unlink()

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

# Admin token: static assets public; /api requires token (css/js must load without ?token=)
python3 - <<PY
import importlib.util
import threading
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

root = Path("$ROOT").resolve()
spec = importlib.util.spec_from_file_location("config_admin", root / "lib" / "config_admin.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)

token = "smoke-admin-token"
app = mod.App(root, token, root / "data" / "watchci.pid")
handler = mod.make_handler(app, token, "127.0.0.1")
ThreadingHTTPServer.allow_reuse_address = True
server = ThreadingHTTPServer(("127.0.0.1", 0), handler)
port = server.server_address[1]
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
base = f"http://127.0.0.1:{port}"

def get(path, headers=None):
    req = urllib.request.Request(base + path, headers=headers or {})
    try:
        with urllib.request.urlopen(req, timeout=2) as resp:
            return resp.status, resp.headers.get("Content-Type", ""), resp.read()
    except urllib.error.HTTPError as e:
        return e.code, e.headers.get("Content-Type", ""), e.read()

try:
    code, ctype, body = get("/style.css")
    assert code == 200, (code, body[:200])
    assert "text/css" in ctype, ctype
    assert b"{" in body or b"." in body, "css body empty?"

    code, _, body = get("/api/config")
    assert code == 401, (code, body)

    code, _, body = get("/api/config", {"X-Admin-Token": token})
    assert code == 200, (code, body[:200])

    code, _, body = get(f"/api/config?token={token}")
    assert code == 200, (code, body[:200])

    code, ctype, body = get(f"/?token={token}")
    assert code == 200, (code, body[:200])
    assert b"style.css" in body
    print("admin token static/api auth ok")
finally:
    server.shutdown()
    server.server_close()
PY

echo "SMOKE OK"
