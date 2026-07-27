#!/usr/bin/env python3
"""Rebuild WatchCI static dashboard from run meta JSON files."""
from __future__ import annotations

import argparse
import html
import json
import shutil
from pathlib import Path


def load_runs(runs_dir: Path) -> list[dict]:
    runs = []
    if not runs_dir.is_dir():
        return runs
    for p in sorted(runs_dir.glob("*.meta.json")):
        try:
            runs.append(json.loads(p.read_text(encoding="utf-8")))
        except (OSError, json.JSONDecodeError):
            continue
    runs.sort(key=lambda r: r.get("finished") or r.get("started") or 0, reverse=True)
    return runs


def copy_log(run: dict, site_dir: Path, log_src: Path | None) -> None:
    run_id = run["id"]
    dest_dir = site_dir / "runs" / run_id
    dest_dir.mkdir(parents=True, exist_ok=True)
    dest_log = dest_dir / "log.txt"
    src = Path(run.get("log") or "")
    if not src.is_file() and log_src:
        # try find under log_src/project/
        project = run.get("project", "")
        candidates = list((log_src / project).glob(f"{run_id}-*.log")) if project else []
        if candidates:
            src = candidates[0]
    if src.is_file():
        shutil.copy2(src, dest_log)
    elif not dest_log.is_file():
        dest_log.write_text("(no log)\n", encoding="utf-8")


def tail_text(path: Path, n: int = 500) -> str:
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ""
    if len(lines) > n:
        return "\n".join(lines[-n:])
    return "\n".join(lines)


def render_run_page(run: dict, site_dir: Path) -> None:
    run_id = run["id"]
    dest_dir = site_dir / "runs" / run_id
    dest_dir.mkdir(parents=True, exist_ok=True)
    log_path = dest_dir / "log.txt"
    log_tail = tail_text(log_path)
    status = html.escape(str(run.get("status", "")))
    body = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>Run {html.escape(run_id)} — WatchCI</title>
<link rel="stylesheet" href="../../assets/style.css"/>
</head>
<body>
<header class="top">
  <a href="../../index.html">← WatchCI</a>
  <h1>Run {html.escape(run_id)}</h1>
</header>
<main>
<table class="meta">
<tr><th>Project</th><td>{html.escape(str(run.get("project","")))}</td></tr>
<tr><th>Status</th><td class="status-{status}">{status}</td></tr>
<tr><th>Kind</th><td>{html.escape(str(run.get("kind","")))}</td></tr>
<tr><th>Ref</th><td>{html.escape(str(run.get("ref","")))}</td></tr>
<tr><th>PR</th><td>{html.escape(str(run.get("pr_id") or "—"))}</td></tr>
<tr><th>SHA</th><td><code>{html.escape(str(run.get("sha","")))}</code></td></tr>
<tr><th>Exit</th><td>{html.escape(str(run.get("exit_code","")))}</td></tr>
<tr><th>Duration</th><td>{html.escape(str(run.get("duration","")))}s</td></tr>
</table>
<p><a href="log.txt">Full log</a></p>
<pre class="log">{html.escape(log_tail)}</pre>
</main>
</body>
</html>
"""
    (dest_dir / "index.html").write_text(body, encoding="utf-8")


def latest_by_project(runs: list[dict]) -> dict[str, dict]:
    out: dict[str, dict] = {}
    for r in runs:
        p = r.get("project") or "?"
        if p not in out:
            out[p] = r
    return out


def render_index(runs: list[dict], site_dir: Path) -> None:
    latest = latest_by_project(runs)
    cards = []
    for project, r in sorted(latest.items()):
        st = html.escape(str(r.get("status", "")))
        cards.append(
            f'<div class="card status-{st}">'
            f"<h2>{html.escape(project)}</h2>"
            f'<p class="badge">{st}</p>'
            f'<p>{html.escape(str(r.get("kind","")))} '
            f'<code>{html.escape(str(r.get("ref","")))}</code> '
            f'{html.escape(str(r.get("sha","")[:8]))}</p>'
            f'<p><a href="runs/{html.escape(r["id"])}/index.html">latest run</a></p>'
            f"</div>"
        )
    rows = []
    for r in runs[:200]:
        st = html.escape(str(r.get("status", "")))
        rows.append(
            "<tr>"
            f'<td><a href="runs/{html.escape(r["id"])}/index.html">{html.escape(r["id"])}</a></td>'
            f'<td>{html.escape(str(r.get("project","")))}</td>'
            f'<td class="status-{st}">{st}</td>'
            f'<td>{html.escape(str(r.get("kind","")))}</td>'
            f'<td>{html.escape(str(r.get("ref","")))}</td>'
            f'<td><code>{html.escape(str(r.get("sha","")[:8]))}</code></td>'
            f'<td>{html.escape(str(r.get("duration","")))}s</td>'
            "</tr>"
        )
    page = f"""<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="utf-8"/>
<meta name="viewport" content="width=device-width, initial-scale=1"/>
<title>WatchCI Dashboard</title>
<link rel="stylesheet" href="assets/style.css"/>
</head>
<body>
<header class="top">
  <h1>WatchCI</h1>
  <p class="sub">Static CI dashboard</p>
</header>
<section class="projects">
{"".join(cards) if cards else "<p>No runs yet.</p>"}
</section>
<section>
  <h2>Recent runs</h2>
  <div class="filters">
    <input id="filter-project" placeholder="Filter project"/>
    <select id="filter-status">
      <option value="">All status</option>
      <option>success</option>
      <option>failure</option>
      <option>timeout</option>
    </select>
  </div>
  <table id="runs-table">
    <thead><tr><th>ID</th><th>Project</th><th>Status</th><th>Kind</th><th>Ref</th><th>SHA</th><th>Dur</th></tr></thead>
    <tbody>
{"".join(rows)}
    </tbody>
  </table>
</section>
<script src="assets/app.js"></script>
</body>
</html>
"""
    (site_dir / "index.html").write_text(page, encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--runs-dir", required=True)
    ap.add_argument("--site-dir", required=True)
    ap.add_argument("--run-id", default="")
    ap.add_argument("--log-src", default="")
    args = ap.parse_args()
    runs_dir = Path(args.runs_dir)
    site_dir = Path(args.site_dir)
    log_src = Path(args.log_src) if args.log_src else None
    site_dir.mkdir(parents=True, exist_ok=True)
    (site_dir / "data").mkdir(parents=True, exist_ok=True)

    runs = load_runs(runs_dir)
    for r in runs:
        copy_log(r, site_dir, log_src)
        render_run_page(r, site_dir)

    (site_dir / "data" / "runs.json").write_text(
        json.dumps(runs, indent=2, ensure_ascii=False) + "\n", encoding="utf-8"
    )
    render_index(runs, site_dir)


if __name__ == "__main__":
    main()
