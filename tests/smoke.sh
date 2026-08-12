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

# Dashboard: same project+PR groups; newest primary; history foldable
python3 - <<PY
import json
from pathlib import Path

runs = Path("$SMOKE_DATA") / "runs"
base = {
    "project": "smoke",
    "kind": "pr",
    "ref": "feat/group",
    "pr_id": "42",
    "sha": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "exit_code": 1,
    "started": 1000,
    "duration": 10,
    "timeout_sec": 60,
    "log": "",
}
(runs / "grp-old.meta.json").write_text(
    json.dumps({**base, "id": "grp-old", "finished": 1000, "status": "failure"}),
    encoding="utf-8",
)
(runs / "grp-new.meta.json").write_text(
    json.dumps(
        {**base, "id": "grp-new", "finished": 2000, "status": "success", "exit_code": 0}
    ),
    encoding="utf-8",
)
PY
"$ROOT/bin/watchci" rebuild-site
idx="$SMOKE_DATA/site/index.html"
grep -q 'group-toggle' "$idx" || { echo "FAIL: missing group-toggle"; exit 1; }
grep -q 'run-history' "$idx" || { echo "FAIL: missing run-history"; exit 1; }
grep -q 'data-group="smoke:42"' "$idx" || { echo "FAIL: missing data-group smoke:42"; exit 1; }
grep -q '<th>Finished</th>' "$idx" || { echo "FAIL: missing Finished column"; exit 1; }
python3 - <<PY
from datetime import datetime
from pathlib import Path
html = Path("$SMOKE_DATA/site/index.html").read_text(encoding="utf-8")
i_new = html.find("grp-new")
i_old = html.find("grp-old")
assert i_new > 0 and i_old > 0 and i_new < i_old, (i_new, i_old)
# grp-old folded under same PR group (not the first history row on page — main may group too)
snip = html[i_new:i_old + 20]
assert 'class="run-history"' in snip and 'data-group="smoke:42"' in snip, snip[:200]
ts_new = datetime.fromtimestamp(2000).strftime("%Y-%m-%d %H:%M:%S")
ts_old = datetime.fromtimestamp(1000).strftime("%Y-%m-%d %H:%M:%S")
assert ts_new in html and ts_old in html, (ts_new, ts_old)
assert html.find(ts_new) < html.find(ts_old), "newer finished time should appear first"
print("pr group dashboard ok")
PY
rm -f "$SMOKE_DATA/runs/grp-old.meta.json" "$SMOKE_DATA/runs/grp-new.meta.json"

# Dashboard: same project+branch (e.g. main) groups like PRs
python3 - <<PY
import json
from pathlib import Path

runs = Path("$SMOKE_DATA") / "runs"
base = {
    "project": "smoke",
    "kind": "branch",
    "ref": "main",
    "pr_id": None,
    "sha": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "exit_code": 1,
    "started": 1000,
    "duration": 10,
    "timeout_sec": 60,
    "log": "",
}
(runs / "br-old.meta.json").write_text(
    json.dumps({**base, "id": "br-old", "finished": 1000, "status": "failure"}),
    encoding="utf-8",
)
(runs / "br-new.meta.json").write_text(
    json.dumps(
        {**base, "id": "br-new", "finished": 2000, "status": "success", "exit_code": 0}
    ),
    encoding="utf-8",
)
PY
"$ROOT/bin/watchci" rebuild-site
idx="$SMOKE_DATA/site/index.html"
grep -q 'data-group="smoke:branch:main"' "$idx" || { echo "FAIL: missing data-group smoke:branch:main"; exit 1; }
python3 - <<PY
from pathlib import Path
html = Path("$SMOKE_DATA/site/index.html").read_text(encoding="utf-8")
# fixture ids may sit under real main runs; require both in the main branch group fold
assert 'data-group="smoke:branch:main"' in html
i_new = html.find("br-new")
i_old = html.find("br-old")
assert i_new > 0 and i_old > 0 and i_new < i_old, (i_new, i_old)
snip = html[html.find('data-group="smoke:branch:main"') : i_old + 20]
assert "br-old" in snip and 'class="run-history"' in snip
print("branch group dashboard ok")
PY
rm -f "$SMOKE_DATA/runs/br-old.meta.json" "$SMOKE_DATA/runs/br-new.meta.json"
"$ROOT/bin/watchci" rebuild-site

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
assert any(f["key"] == "SKIP_IF_PR_SUCCESS_COMMENT" for f in mod.PROJECT_SCHEMA)
assert "skipped" in mod.RERUN_STATUSES
assert "failure" in mod.RERUN_STATUSES
gfr = next(f for f in mod.GLOBAL_SCHEMA if f["key"] == "DEFAULT_FAIL_RETRIES")
assert "最大 8" in gfr["help"]
pfr = next(f for f in mod.PROJECT_SCHEMA if f["key"] == "FAIL_RETRIES")
assert "最大 8" in pfr["help"]
out = mod.dump_conf({"NAME": "x", "ENABLED": "true"}, mod.PROJECT_SCHEMA)
assert "项目名称" in out or "NAME=x" in out
assert "# " in out
# SCRIPT with args must be quoted for bash source; round-trip keeps value
quoted = mod.dump_conf({"SCRIPT": "./ci.sh --quick --flag=1"}, mod.PROJECT_SCHEMA)
assert "SCRIPT='./ci.sh --quick --flag=1'" in quoted or 'SCRIPT="./ci.sh' in quoted
assert mod.parse_conf(quoted)["SCRIPT"] == "./ci.sh --quick --flag=1"
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

# SCRIPT path + args split (first token resolves; rest passed through)
bash -c '
  set -euo pipefail
  ROOT="'"$ROOT"'"
  TMP="'"$TMP"'"
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/runner.sh"
  CLONE_DIR="$TMP/script-args-clone"
  mkdir -p "$CLONE_DIR"
  printf "%s\n" "#!/usr/bin/env bash" "printf \"%s\\n\" \"\$@\"" >"$CLONE_DIR/ci.sh"
  chmod +x "$CLONE_DIR/ci.sh"
  SCRIPT="./ci.sh --mode full"
  _SCRIPT_CMDLINE=()
  _script_cmdline
  [[ "${_SCRIPT_CMDLINE[0]}" == "$CLONE_DIR/ci.sh" || "${_SCRIPT_CMDLINE[0]}" == "$CLONE_DIR/./ci.sh" ]] \
    || { echo "FAIL: path ${_SCRIPT_CMDLINE[0]}"; exit 1; }
  [[ "${#_SCRIPT_CMDLINE[@]}" -eq 3 && "${_SCRIPT_CMDLINE[1]}" == "--mode" && "${_SCRIPT_CMDLINE[2]}" == "full" ]] \
    || { echo "FAIL: args ${_SCRIPT_CMDLINE[*]}"; exit 1; }
  # execute via same argv shape runner uses
  got0=
  got1=
  {
    read -r got0
    read -r got1
  } < <(bash "${_SCRIPT_CMDLINE[@]}")
  [[ "$got0" == "--mode" && "$got1" == "full" ]] || { echo "FAIL: exec got0=$got0 got1=$got1"; exit 1; }
  echo "script args ok"
'

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

# FAIL_RETRIES / DEFAULT_FAIL_RETRIES: defaults, clamp, inherit
bash -c '
  source "'"$ROOT"'/lib/config.sh"
  export WATCHCI_ROOT="'"$ROOT"'"
  export CONFIG_DIR="'"$TMP"'/config"
  export GLOBAL_CONF="'"$TMP"'/config/watchci.conf"
  export PROJECTS_DIR="'"$TMP"'/config/projects"
  load_global_config
  [[ "${DEFAULT_FAIL_RETRIES:-}" == "1" ]] || { echo "FAIL: default DEFAULT_FAIL_RETRIES want 1 got $DEFAULT_FAIL_RETRIES"; exit 1; }
  load_project_file "'"$TMP"'/config/projects/smoke.conf"
  [[ "$FAIL_RETRIES" == "1" ]] || { echo "FAIL: empty FAIL_RETRIES should inherit 1 got $FAIL_RETRIES"; exit 1; }

  # project =0 stays 0
  echo "FAIL_RETRIES=0" >>"'"$TMP"'/config/projects/smoke.conf"
  load_project_file "'"$TMP"'/config/projects/smoke.conf"
  [[ "$FAIL_RETRIES" == "0" ]] || { echo "FAIL: FAIL_RETRIES=0 want 0 got $FAIL_RETRIES"; exit 1; }

  # negative → fallback DEFAULT
  sed -i.bak "s/^FAIL_RETRIES=.*/FAIL_RETRIES=-1/" "'"$TMP"'/config/projects/smoke.conf"
  load_project_file "'"$TMP"'/config/projects/smoke.conf"
  [[ "$FAIL_RETRIES" == "1" ]] || { echo "FAIL: FAIL_RETRIES=-1 want 1 got $FAIL_RETRIES"; exit 1; }

  # non-numeric → fallback
  sed -i.bak "s/^FAIL_RETRIES=.*/FAIL_RETRIES=abc/" "'"$TMP"'/config/projects/smoke.conf"
  load_project_file "'"$TMP"'/config/projects/smoke.conf"
  [[ "$FAIL_RETRIES" == "1" ]] || { echo "FAIL: FAIL_RETRIES=abc want 1 got $FAIL_RETRIES"; exit 1; }

  # >8 → clamp 8
  sed -i.bak "s/^FAIL_RETRIES=.*/FAIL_RETRIES=99/" "'"$TMP"'/config/projects/smoke.conf"
  load_project_file "'"$TMP"'/config/projects/smoke.conf"
  [[ "$FAIL_RETRIES" == "8" ]] || { echo "FAIL: FAIL_RETRIES=99 want 8 got $FAIL_RETRIES"; exit 1; }

  # global DEFAULT_FAIL_RETRIES clamp / invalid
  echo "DEFAULT_FAIL_RETRIES=0" >>"'"$TMP"'/config/watchci.conf"
  load_global_config
  [[ "$DEFAULT_FAIL_RETRIES" == "0" ]] || { echo "FAIL: DEFAULT_FAIL_RETRIES=0 want 0 got $DEFAULT_FAIL_RETRIES"; exit 1; }
  sed -i.bak "s/^DEFAULT_FAIL_RETRIES=.*/DEFAULT_FAIL_RETRIES=-3/" "'"$TMP"'/config/watchci.conf"
  load_global_config
  [[ "$DEFAULT_FAIL_RETRIES" == "1" ]] || { echo "FAIL: DEFAULT_FAIL_RETRIES=-3 want 1 got $DEFAULT_FAIL_RETRIES"; exit 1; }
  sed -i.bak "s/^DEFAULT_FAIL_RETRIES=.*/DEFAULT_FAIL_RETRIES=xyz/" "'"$TMP"'/config/watchci.conf"
  load_global_config
  [[ "$DEFAULT_FAIL_RETRIES" == "1" ]] || { echo "FAIL: DEFAULT_FAIL_RETRIES=xyz want 1 got $DEFAULT_FAIL_RETRIES"; exit 1; }
  sed -i.bak "s/^DEFAULT_FAIL_RETRIES=.*/DEFAULT_FAIL_RETRIES=99/" "'"$TMP"'/config/watchci.conf"
  load_global_config
  [[ "$DEFAULT_FAIL_RETRIES" == "8" ]] || { echo "FAIL: DEFAULT_FAIL_RETRIES=99 want 8 got $DEFAULT_FAIL_RETRIES"; exit 1; }
  # restore defaults for later smoke
  sed -i.bak "s/^DEFAULT_FAIL_RETRIES=.*/DEFAULT_FAIL_RETRIES=1/" "'"$TMP"'/config/watchci.conf"
  sed -i.bak "/^FAIL_RETRIES=/d" "'"$TMP"'/config/projects/smoke.conf"
  load_global_config
  echo "fail_retries clamp ok"
'

# Instant fail-retry: flaky SCRIPT succeeds on 2nd try; one meta, no extra pending
cat >"$TMP/work/flaky-ci.sh" <<'EOF'
#!/usr/bin/env bash
# State outside clone — checkout between retries wipes the tree.
MARKER="${WATCHCI_LOG}.flaky_once"
if [[ -f "$MARKER" ]]; then
  rm -f "$MARKER"
  exit 0
fi
touch "$MARKER"
exit 1
EOF
chmod +x "$TMP/work/flaky-ci.sh"
git -C "$TMP/work" add flaky-ci.sh
git -C "$TMP/work" commit -q -m "flaky script"
git -C "$TMP/work" push -q origin main
FLAKY_SHA="$(git -C "$TMP/work" rev-parse HEAD)"
# Ensure FAIL_RETRIES=1 (default) and SCRIPT points at flaky
grep -q '^FAIL_RETRIES=' "$TMP/config/projects/smoke.conf" && sed -i.bak '/^FAIL_RETRIES=/d' "$TMP/config/projects/smoke.conf"
sed -i.bak "s|^SCRIPT=.*|SCRIPT=./flaky-ci.sh|" "$TMP/config/projects/smoke.conf"
before_metas=$(find "$SMOKE_DATA/runs" -name '*.meta.json' 2>/dev/null | wc -l | tr -d ' ')
bash -c '
  source "'"$ROOT"'/lib/common.sh"
  source "'"$ROOT"'/lib/config.sh"
  source "'"$ROOT"'/lib/events.sh"
  export WATCHCI_ROOT="'"$ROOT"'"
  export CONFIG_DIR="'"$TMP"'/config"
  export GLOBAL_CONF="'"$TMP"'/config/watchci.conf"
  export PROJECTS_DIR="'"$TMP"'/config/projects"
  load_global_config
  event_enqueue smoke branch main "'"$FLAKY_SHA"'" "" smoke
'
"$ROOT/bin/watchci" tick
pending_left=$(find "$SMOKE_DATA/events/pending" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$pending_left" == "0" ]] || { echo "FAIL: pending left after flaky retry ($pending_left)"; ls -la "$SMOKE_DATA/events/pending"; exit 1; }
after_metas=$(find "$SMOKE_DATA/runs" -name '*.meta.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$after_metas" -eq $((before_metas + 1)) ]] || { echo "FAIL: flaky retry should add exactly 1 meta (before=$before_metas after=$after_metas)"; exit 1; }
flaky_meta=""
for m in "$SMOKE_DATA"/runs/*.meta.json; do
  if grep -q "$FLAKY_SHA" "$m" && grep -q '"status": "success"' "$m"; then
    flaky_meta="$m"
    break
  fi
done
[[ -n "$flaky_meta" ]] || { echo "FAIL: flaky retry meta not success"; exit 1; }
grep -q '"attempts": 2' "$flaky_meta" || grep -q '"attempts":2' "$flaky_meta" || { echo "FAIL: expected attempts=2 in $flaky_meta"; cat "$flaky_meta"; exit 1; }
flaky_log="$(python3 -c "import json; print(json.load(open('$flaky_meta'))['log'])")"
grep -q '=== retry 1/1 after exit=1 ===' "$flaky_log" || { echo "FAIL: missing retry mark in log"; cat "$flaky_log"; exit 1; }
echo "fail retry instant ok"

# FAIL_RETRIES=0: fail once, no retry
cat >"$TMP/work/always-fail.sh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$TMP/work/always-fail.sh"
git -C "$TMP/work" add always-fail.sh
git -C "$TMP/work" commit -q -m "always fail"
git -C "$TMP/work" push -q origin main
FAIL0_SHA="$(git -C "$TMP/work" rev-parse HEAD)"
sed -i.bak "s|^SCRIPT=.*|SCRIPT=./always-fail.sh|" "$TMP/config/projects/smoke.conf"
echo "FAIL_RETRIES=0" >>"$TMP/config/projects/smoke.conf"
before_metas=$(find "$SMOKE_DATA/runs" -name '*.meta.json' 2>/dev/null | wc -l | tr -d ' ')
bash -c '
  source "'"$ROOT"'/lib/common.sh"
  source "'"$ROOT"'/lib/config.sh"
  source "'"$ROOT"'/lib/events.sh"
  export WATCHCI_ROOT="'"$ROOT"'"
  export CONFIG_DIR="'"$TMP"'/config"
  export GLOBAL_CONF="'"$TMP"'/config/watchci.conf"
  export PROJECTS_DIR="'"$TMP"'/config/projects"
  load_global_config
  event_enqueue smoke branch main "'"$FAIL0_SHA"'" "" smoke
'
"$ROOT/bin/watchci" tick
fail0_meta=""
for m in "$SMOKE_DATA"/runs/*.meta.json; do
  if grep -q "$FAIL0_SHA" "$m"; then
    fail0_meta="$m"
    break
  fi
done
[[ -n "$fail0_meta" ]] || { echo "FAIL: no meta for FAIL_RETRIES=0 run"; exit 1; }
grep -q '"status": "failure"' "$fail0_meta" || grep -q '"status":"failure"' "$fail0_meta" || { echo "FAIL: expected failure"; cat "$fail0_meta"; exit 1; }
grep -q '"attempts": 1' "$fail0_meta" || grep -q '"attempts":1' "$fail0_meta" || { echo "FAIL: expected attempts=1"; cat "$fail0_meta"; exit 1; }
fail0_log="$(python3 -c "import json; print(json.load(open('$fail0_meta'))['log'])")"
grep -q '=== retry' "$fail0_log" && { echo "FAIL: FAIL_RETRIES=0 should not retry"; cat "$fail0_log"; exit 1; }
after_metas=$(find "$SMOKE_DATA/runs" -name '*.meta.json' 2>/dev/null | wc -l | tr -d ' ')
[[ "$after_metas" -eq $((before_metas + 1)) ]] || { echo "FAIL: FAIL_RETRIES=0 should add 1 meta"; exit 1; }
# restore SCRIPT for later tests that expect run-ci.sh success
sed -i.bak "s|^SCRIPT=.*|SCRIPT=./run-ci.sh|" "$TMP/config/projects/smoke.conf"
sed -i.bak '/^FAIL_RETRIES=/d' "$TMP/config/projects/smoke.conf"
echo "fail retries=0 no-retry ok"

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

# webhook: WIP/draft PR ignored
pr_wip='{"action":"opened","pull_request":{"number":122,"title":"[WIP] feat","draft":true,"head":{"sha":"dddddddddddddddddddddddddddddddddddddddd","ref":"feat/wip"},"base":{"ref":"main"}}}'
out="$(echo "$pr_wip" | WATCHCI_PROJECT=smoke WATCHCI_BRANCHES=main "$ROOT/hooks/webhook_ingest.sh" github pull_request || true)"
[[ -z "$out" ]] || { echo "FAIL: WIP PR should be ignored"; echo "$out"; exit 1; }
echo "webhook pr wip skip ok"

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
import os
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

# skipped status is rerunnable (force re-run after success-comment skip)
for f in pending.glob("*.json"):
    f.unlink()
skip_id = "smoke-skip-rerun-1"
skip_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
(runs / f"{skip_id}.meta.json").write_text(
    json.dumps(
        {
            **meta,
            "id": skip_id,
            "kind": "pr",
            "ref": "feat/skip",
            "pr_id": "42",
            "sha": skip_sha,
            "status": "skipped",
            "exit_code": 0,
            "finished": 40,
        }
    ),
    encoding="utf-8",
)
(state_dir / "smoke.tsv").write_text(
    f"pr\t42\t{skip_sha}\tskipped\t{skip_id}\t2026-01-01T00:00:00Z\n",
    encoding="utf-8",
)
assert skip_id in {r["id"] for r in app.list_runs()}
rs = app.rerun_run(skip_id)
assert rs.get("ok") and rs.get("event_id"), rs
evs = json.loads(list(pending.glob("*.json"))[0].read_text(encoding="utf-8"))
assert evs["source"] == "manual" and evs["sha"] == skip_sha and evs["pr_id"] == "42"
assert not (runs / f"{skip_id}.meta.json").is_file()
for f in pending.glob("*.json"):
    f.unlink()

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

# 现场：仅 UI 在线时 /api/live 应带守护进程告警
pid_path = data / "watchci.pid"
pid_path.unlink(missing_ok=True)
app_live = mod.App(root, "", pid_path)
snap = app_live.live_snapshot()
assert snap["daemon"] == "stopped", snap
assert snap.get("alert"), snap
assert "未运行" in snap["alert"], snap
pid_path.write_text(str(os.getpid()) + "\n", encoding="utf-8")
snap_ok = app_live.live_snapshot()
assert snap_ok["daemon"] == "running", snap_ok
assert not snap_ok.get("alert"), snap_ok
pid_path.unlink(missing_ok=True)
print("daemon live alert ok")
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

# PR sticky comment: find marker + body builder + github upsert via fake curl
bash -c '
  set -euo pipefail
  ROOT="'"$ROOT"'"
  TMP="'"$TMP"'"
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/adapters/_interface.sh"

  found="$(printf "%s" "[{\"id\":1,\"body\":\"hello\"},{\"id\":99,\"body\":\"x <!-- watchci --> y\"}]" | provider_comment_find_id)"
  [[ "$found" == "99" ]] || { echo "FAIL: find id got=$found"; exit 1; }
  empty="$(printf "%s" "[{\"id\":1,\"body\":\"nope\"}]" | provider_comment_find_id)"
  [[ -z "$empty" ]] || { echo "FAIL: expect empty got=$empty"; exit 1; }
  echo "pr comment find id ok"

  success_body="$(printf "%s\n" "### ✅ WatchCI · success" "" "- sha: \`abcdef01\`" "" "<!-- watchci -->")"
  fail_body="$(printf "%s\n" "### ❌ WatchCI · failure" "" "- sha: \`abcdef01\`" "" "<!-- watchci -->")"
  provider_comment_skip_downgrade "$success_body" "failure" "abcdef0123456789" || { echo "FAIL: expect skip failure same sha"; exit 1; }
  provider_comment_skip_downgrade "$success_body" "timeout" "abcdef0123456789" || { echo "FAIL: expect skip timeout same sha"; exit 1; }
  provider_comment_skip_downgrade "$success_body" "failure" "deadbeef12345678" && { echo "FAIL: different sha should not skip"; exit 1; }
  provider_comment_skip_downgrade "$fail_body" "failure" "abcdef0123456789" && { echo "FAIL: old failure should not skip"; exit 1; }
  provider_comment_skip_downgrade "$success_body" "success" "abcdef0123456789" && { echo "FAIL: new success should not skip"; exit 1; }
  echo "pr comment skip downgrade ok"

  provider_comment_is_success_for_sha "$success_body" "abcdef0123456789" || { echo "FAIL: expect success for sha"; exit 1; }
  provider_comment_is_success_for_sha "$success_body" "deadbeef12345678" && { echo "FAIL: different sha not success"; exit 1; }
  provider_comment_is_success_for_sha "$fail_body" "abcdef0123456789" && { echo "FAIL: failure body not success"; exit 1; }
  echo "pr comment is success for sha ok"

  # WIP/draft filter (provider_jq_skip_wip); avoid single quotes in this bash -c block
  wip_in="$(jq -n "[
    {\"number\":1,\"title\":\"feat: normal\",\"draft\":false},
    {\"number\":2,\"title\":\"[WIP] feat(kv-cache): pool\",\"draft\":true},
    {\"number\":3,\"title\":\"[WIP]更多冒烟\",\"draft\":true},
    {\"number\":4,\"title\":\"feat: almost done\",\"draft\":true},
    {\"number\":5,\"title\":\"[wip] lowercase\",\"draft\":false},
    {\"number\":6,\"title\":\"ready\",\"work_in_progress\":true}
  ]")"
  wip_out="$(printf "%s" "$wip_in" | provider_jq_skip_wip)"
  nums="$(echo "$wip_out" | jq -r "[.[].number] | join(\",\")")"
  [[ "$nums" == "1" ]] || { echo "FAIL: skip wip got numbers=$nums want=1"; exit 1; }
  echo "provider_jq_skip_wip ok"

  # shellcheck source=/dev/null
  source "$ROOT/lib/report.sh"
  meta="$TMP/pr-comment.meta.json"
  cat >"$meta" <<EOF
{"id":"run-abc","project":"demo","kind":"pr","pr_id":"7","sha":"abcdef0123456789","status":"success","exit_code":0,"duration":12,"attempts":1,"finished":1700000000}
EOF
  SITE_PUBLIC_URL="https://ci.example.com"
  body="$(report_pr_comment_body "$meta")"
  echo "$body" | grep -q "✅ WatchCI · success" || { echo "FAIL: body status"; exit 1; }
  echo "$body" | grep -q "https://ci.example.com/runs/run-abc/" || { echo "FAIL: body link"; exit 1; }
  echo "$body" | grep -q "<!-- watchci -->" || { echo "FAIL: body marker"; exit 1; }
  echo "$body" | grep -qE '^- updated: [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2}:[0-9]{2}$' || { echo "FAIL: body updated"; echo "$body"; exit 1; }
  # failure / timeout headlines
  cat >"$meta" <<EOF
{"id":"run-fail","project":"demo","kind":"pr","pr_id":"7","sha":"abcdef01","status":"failure","exit_code":1,"duration":3,"attempts":2}
EOF
  body="$(report_pr_comment_body "$meta")"
  echo "$body" | grep -q "❌ WatchCI · failure" || { echo "FAIL: body failure"; exit 1; }
  cat >"$meta" <<EOF
{"id":"run-to","project":"demo","kind":"pr","pr_id":"7","sha":"abcdef01","status":"timeout","exit_code":124,"duration":60,"attempts":1}
EOF
  body="$(report_pr_comment_body "$meta")"
  echo "$body" | grep -q "⏰ WatchCI · timeout" || { echo "FAIL: body timeout"; exit 1; }
  echo "pr comment body ok"

  fake="$TMP/fake-curl-bin"
  mkdir -p "$fake"
  # Write fake curl outside nested quoting; path via env for the script body.
  cat >"$fake/curl" <<'"'"'FAKE'"'"'
#!/usr/bin/env bash
set -euo pipefail
log="${FAKE_CURL_LOG:?}"
printf "%s\n" "$*" >>"$log"
method=GET
url=""
prev=""
for a in "$@"; do
  if [[ "$prev" == "-X" ]]; then
    method="$a"
  fi
  case "$a" in
    http://*|https://*) url="$a" ;;
  esac
  prev="$a"
done
case "$method:$url" in
  GET:*/issues/*/comments*)
    if [[ "${FAKE_COMMENT_BODY:-}" == "success" ]]; then
      printf "%s\n" "[{\"id\":42,\"body\":\"### ✅ WatchCI · success\\n\\n- sha: \`abcdef01\`\\n\\n<!-- watchci -->\"}]"
    else
      printf "%s\n" "[{\"id\":42,\"body\":\"old <!-- watchci -->\"}]"
    fi
    exit 0
    ;;
  PATCH:*/issues/comments/42*)
    printf "%s\n" "{\"id\":42}"
    exit 0
    ;;
esac
echo "unexpected curl method=$method url=$url" >&2
exit 1
FAKE
  chmod +x "$fake/curl"
  export PATH="$fake:$PATH"
  export FAKE_CURL_LOG="$TMP/fake-curl.log"
  : >"$FAKE_CURL_LOG"
  export OWNER=o REPO=r TOKEN_ENV=GITHUB_TOKEN GITHUB_TOKEN=tok
  # shellcheck source=/dev/null
  source "$ROOT/adapters/github.sh"
  provider_upsert_pr_comment 3 "WatchCI sticky <!-- watchci -->" "failure" "deadbeef"
  grep -q "PATCH" "$FAKE_CURL_LOG" || { echo "FAIL: expected PATCH"; cat "$FAKE_CURL_LOG"; exit 1; }
  if grep -q " -X POST\|POST " "$FAKE_CURL_LOG"; then
    echo "FAIL: should not POST"; cat "$FAKE_CURL_LOG"; exit 1
  fi
  echo "pr comment sticky update ok"

  : >"$FAKE_CURL_LOG"
  export FAKE_COMMENT_BODY=success
  provider_upsert_pr_comment 3 "new failure body <!-- watchci -->" "failure" "abcdef0123456789"
  if grep -q "PATCH" "$FAKE_CURL_LOG"; then
    echo "FAIL: should skip downgrade PATCH"; cat "$FAKE_CURL_LOG"; exit 1
  fi
  if grep -q " -X POST\|POST " "$FAKE_CURL_LOG"; then
    echo "FAIL: should not POST on skip"; cat "$FAKE_CURL_LOG"; exit 1
  fi
  grep -q "comments" "$FAKE_CURL_LOG" || { echo "FAIL: expected GET comments"; cat "$FAKE_CURL_LOG"; exit 1; }
  echo "pr comment skip downgrade upsert ok"
'

# --- PR merge dedup + daily ---
bash -c '
  set -euo pipefail
  ROOT="'"$ROOT"'"
  TMP="'"$TMP"'"
  SMOKE_DATA="'"$SMOKE_DATA"'"
  export WATCHCI_ROOT="$ROOT"
  export CONFIG_DIR="$TMP/config"
  export GLOBAL_CONF="$TMP/config/watchci.conf"
  export PROJECTS_DIR="$TMP/config/projects"
  # shellcheck source=/dev/null
  source "$ROOT/lib/common.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/config.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/state.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/events.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/poll.sh"
  load_global_config
  load_project_file "$PROJECTS_DIR/smoke.conf"
  state_ensure
  ensure_clone
  git -C "$CLONE_DIR" fetch --prune --no-recurse-submodules origin >/dev/null 2>&1

  MAIN_SHA="$(git -C "$CLONE_DIR" rev-parse refs/remotes/origin/main)"
  # Simulate prior successful PR CI at MAIN_SHA + branch already ran once
  mkdir -p "$DATA_DIR/runs"
  cat >"$DATA_DIR/runs/pr-cover.meta.json" <<EOF
{"id":"pr-cover","project":"smoke","kind":"pr","pr_id":"99","ref":"feat/x","sha":"$MAIN_SHA","status":"success","exit_code":0,"started":1,"finished":2,"duration":1,"attempts":1,"log":""}
EOF
  state_set branch main "$MAIN_SHA" success prior-run

  # Fake tip change to same SHA (state already at MAIN_SHA) — bump state back then poll
  # Create a feature commit, push as PR head, then FF main to it (covered)
  git -C "$TMP/work" checkout -q main
  git -C "$TMP/work" pull -q origin main
  echo "ff-cover" >"$TMP/work/ff-cover.txt"
  git -C "$TMP/work" add ff-cover.txt
  git -C "$TMP/work" commit -q -m "ff-cover"
  FF_SHA="$(git -C "$TMP/work" rev-parse HEAD)"
  git -C "$TMP/work" push -q origin "HEAD:refs/pull/99/head"
  # Pretend we already ran successful PR CI on this head
  cat >"$DATA_DIR/runs/pr-cover.meta.json" <<EOF
{"id":"pr-cover","project":"smoke","kind":"pr","pr_id":"99","ref":"feat/x","sha":"$FF_SHA","status":"success","exit_code":0,"started":1,"finished":2,"duration":1,"attempts":1,"log":""}
EOF
  # Keep branch state at old tip with last_run_id, then FF main
  state_set branch main "$MAIN_SHA" success prior-run
  git -C "$TMP/work" push -q origin main
  rm -f "$DATA_DIR/events/pending"/*.json 2>/dev/null || true
  poll_branches
  pending_n=$(find "$DATA_DIR/events/pending" -name "*.json" 2>/dev/null | wc -l | tr -d " ")
  [[ "$pending_n" -eq 0 ]] || { echo "FAIL: FF covered by PR CI should not enqueue ($pending_n)"; ls "$DATA_DIR/events/pending"; exit 1; }
  tracked="$(state_get_sha branch main)"
  [[ "$tracked" == "$FF_SHA" ]] || { echo "FAIL: state should update to FF tip"; exit 1; }
  echo "pr merge FF skip ok"

  # No last_run_id: still enqueue even if PR covers
  echo "first-run" >"$TMP/work/first-run.txt"
  git -C "$TMP/work" add first-run.txt
  git -C "$TMP/work" commit -q -m "first-run"
  FR_SHA="$(git -C "$TMP/work" rev-parse HEAD)"
  git -C "$TMP/work" push -q origin main
  cat >"$DATA_DIR/runs/pr-cover2.meta.json" <<EOF
{"id":"pr-cover2","project":"smoke","kind":"pr","pr_id":"100","ref":"feat/y","sha":"$FR_SHA","status":"success","exit_code":0,"started":1,"finished":2,"duration":1,"attempts":1,"log":""}
EOF
  # state with sha old but empty run_id
  sf="$(state_file)"
  TAB=$(printf \\t)
  : >"$sf.tmp"
  while IFS= read -r line || [[ -n "${line:-}" ]]; do
    [[ -z "${line:-}" ]] && continue
    case "$line" in
      branch${TAB}main${TAB}*) ;;
      *) printf "%s\n" "$line" >>"$sf.tmp" ;;
    esac
  done <"$sf"
  mv "$sf.tmp" "$sf"
  printf "branch\tmain\t%s\t\t\t%s\n" "$FF_SHA" "$(iso_now)" >>"$sf"
  rm -f "$DATA_DIR/events/pending"/*.json 2>/dev/null || true
  poll_branches
  pending_n=$(find "$DATA_DIR/events/pending" -name "*.json" 2>/dev/null | wc -l | tr -d " ")
  [[ "$pending_n" -ge 1 ]] || { echo "FAIL: no last_run_id should still enqueue"; exit 1; }
  # drop pending so later tests are clean
  rm -f "$DATA_DIR/events/pending"/*.json 2>/dev/null || true
  state_set branch main "$FR_SHA" success after-first
  echo "no last_run_id still enqueue ok"

  # Direct push (no PR meta for new tip) → enqueue
  echo "direct" >"$TMP/work/direct.txt"
  git -C "$TMP/work" add direct.txt
  git -C "$TMP/work" commit -q -m "direct"
  DIR_SHA="$(git -C "$TMP/work" rev-parse HEAD)"
  git -C "$TMP/work" push -q origin main
  rm -f "$DATA_DIR/events/pending"/*.json 2>/dev/null || true
  poll_branches
  pending_n=$(find "$DATA_DIR/events/pending" -name "*.json" 2>/dev/null | wc -l | tr -d " ")
  [[ "$pending_n" -ge 1 ]] || { echo "FAIL: direct push should enqueue"; exit 1; }
  grep -q "\"source\": \"poll\"" "$DATA_DIR/events/pending"/*.json \
    || grep -q "\"source\":\"poll\"" "$DATA_DIR/events/pending"/*.json \
    || { echo "FAIL: expected source=poll"; cat "$DATA_DIR/events/pending"/*.json; exit 1; }
  rm -f "$DATA_DIR/events/pending"/*.json 2>/dev/null || true
  state_set branch main "$DIR_SHA" success after-direct
  echo "direct push enqueue ok"

  # Daily: enable, DAILY_AT in the past, no branch meta today → enqueue daily
  # Wipe today branch metas for smoke project main (keep others)
  python3 - <<PY
import json, time
from pathlib import Path
runs = Path("$SMOKE_DATA") / "runs"
today = time.strftime("%Y-%m-%d")
for p in runs.glob("*.meta.json"):
    m = json.loads(p.read_text())
    if m.get("project") != "smoke" or m.get("kind") != "branch" or m.get("ref") != "main":
        continue
    fin = m.get("finished")
    if fin is None:
        continue
    day = time.strftime("%Y-%m-%d", time.localtime(int(fin)))
    if day == today:
        # move finished to yesterday so daily can fire
        m["finished"] = int(fin) - 86400
        p.write_text(json.dumps(m))
PY
  cat >>"$PROJECTS_DIR/smoke.conf" <<EOF
DAILY_ENABLE=true
DAILY_AT=00:00
DAILY_BRANCH=main
DAILY_SCRIPT=./daily-ci.sh
EOF
  printf "%s\n" "#!/usr/bin/env bash" "echo DAILY_RAN" "exit 0" >"$TMP/work/daily-ci.sh"
  chmod +x "$TMP/work/daily-ci.sh"
  git -C "$TMP/work" add daily-ci.sh
  git -C "$TMP/work" commit -q -m "daily script"
  git -C "$TMP/work" push -q origin main
  # absorb the push enqueue without running (state tip)
  NEW_SHA="$(git -C "$TMP/work" rev-parse HEAD)"
  git -C "$CLONE_DIR" fetch --prune --no-recurse-submodules origin >/dev/null 2>&1
  rm -f "$DATA_DIR/events/pending"/*.json 2>/dev/null || true
  state_set branch main "$NEW_SHA" success after-daily-script
  load_project_file "$PROJECTS_DIR/smoke.conf"
  poll_daily
  pending_n=$(find "$DATA_DIR/events/pending" -name "*.json" 2>/dev/null | wc -l | tr -d " ")
  [[ "$pending_n" -eq 1 ]] || { echo "FAIL: daily should enqueue once got=$pending_n"; ls "$DATA_DIR/events/pending" || true; exit 1; }
  grep -q "\"source\": \"daily\"" "$DATA_DIR/events/pending"/*.json \
    || grep -q "\"source\":\"daily\"" "$DATA_DIR/events/pending"/*.json \
    || { echo "FAIL: expected source=daily"; cat "$DATA_DIR/events/pending"/*.json; exit 1; }
  # second poll_daily dedups
  poll_daily
  pending_n=$(find "$DATA_DIR/events/pending" -name "*.json" 2>/dev/null | wc -l | tr -d " ")
  [[ "$pending_n" -eq 1 ]] || { echo "FAIL: daily dedup failed got=$pending_n"; exit 1; }
  echo "daily enqueue ok"

  # Run daily event → DAILY_SCRIPT
  # shellcheck source=/dev/null
  source "$ROOT/lib/site.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/report.sh"
  # shellcheck source=/dev/null
  source "$ROOT/lib/runner.sh"
  drain_events
  daily_meta=""
  for m in "$DATA_DIR"/runs/*.meta.json; do
    if grep -q "\"source\": \"daily\"" "$m" || grep -q "\"source\":\"daily\"" "$m"; then
      daily_meta="$m"
    fi
  done
  [[ -n "$daily_meta" ]] || { echo "FAIL: no daily meta"; exit 1; }
  dlog="$(python3 -c "import json; print(json.load(open(\"$daily_meta\"))[\"log\"])")"
  grep -q "DAILY_RAN" "$dlog" || { echo "FAIL: DAILY_SCRIPT not run"; cat "$dlog"; exit 1; }
  grep -q "daily-ci.sh" "$dlog" || { echo "FAIL: expected daily-ci.sh in log"; cat "$dlog"; exit 1; }
  echo "daily script ok"

  # Today already has branch run → poll_daily no-op
  rm -f "$DATA_DIR/events/pending"/*.json 2>/dev/null || true
  poll_daily
  pending_n=$(find "$DATA_DIR/events/pending" -name "*.json" 2>/dev/null | wc -l | tr -d " ")
  [[ "$pending_n" -eq 0 ]] || { echo "FAIL: daily should skip when branch ran today"; exit 1; }
  echo "daily skip when ran today ok"
'

echo "SMOKE OK"
