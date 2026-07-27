#!/usr/bin/env python3
"""Local config admin HTTP server for WatchCI (stdlib only)."""
from __future__ import annotations

import argparse
import json
import os
import re
import signal
import tempfile
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlparse

NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")

GLOBAL_FIELDS = [
    "DATA_DIR",
    "POLL_INTERVAL_SEC",
    "MAX_PARALLEL_RUNS",
    "DEFAULT_TIMEOUT_SEC",
    "SITE_DIR",
    "PUBLISH_CMD",
    "AUTO_PUBLISH",
    "PID_FILE",
    "LOG_FILE",
    "ADMIN_PID_FILE",
    "ADMIN_BIND",
    "ADMIN_PORT",
    "ADMIN_TOKEN",
    "ADMIN_ENABLE",
]

PROJECT_FIELDS = [
    "NAME",
    "PROVIDER",
    "REPO_URL",
    "API_BASE",
    "OWNER",
    "REPO",
    "PROJECT_ID",
    "BRANCHES",
    "WATCH_PRS",
    "PR_LABELS",
    "SCRIPT",
    "WORKDIR",
    "TIMEOUT_SEC",
    "POLL_INTERVAL_SEC",
    "TOKEN_ENV",
    "CLONE_DIR",
    "ENABLED",
]


def parse_conf(text: str) -> dict[str, str]:
    data: dict[str, str] = {}
    for line in text.splitlines():
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        if "=" not in s:
            continue
        k, v = s.split("=", 1)
        data[k.strip()] = v.strip().strip('"').strip("'")
    return data


def dump_conf(data: dict[str, str], field_order: list[str]) -> str:
    lines = ["# Managed by WatchCI admin UI", ""]
    seen = set()
    for k in field_order:
        if k in data:
            lines.append(f"{k}={data[k]}")
            seen.add(k)
    for k, v in data.items():
        if k not in seen:
            lines.append(f"{k}={v}")
    lines.append("")
    return "\n".join(lines)


def atomic_write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=path.name + ".")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp, path)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


class App:
    def __init__(self, root: Path, token: str, daemon_pid_file: Path):
        self.root = root
        self.token = token
        self.daemon_pid_file = daemon_pid_file
        self.config_dir = root / "config"
        self.global_conf = self.config_dir / "watchci.conf"
        self.projects_dir = self.config_dir / "projects"
        self.admin_ui = root / "admin_ui"

    def ensure_global(self) -> None:
        if not self.global_conf.is_file():
            example = self.config_dir / "watchci.conf.example"
            if example.is_file():
                atomic_write(self.global_conf, example.read_text(encoding="utf-8"))
            else:
                atomic_write(self.global_conf, dump_conf({}, GLOBAL_FIELDS))

    def read_global(self) -> dict[str, str]:
        self.ensure_global()
        return parse_conf(self.global_conf.read_text(encoding="utf-8"))

    def write_global(self, data: dict[str, str]) -> None:
        cur = self.read_global()
        cur.update({k: str(v) for k, v in data.items() if v is not None})
        atomic_write(self.global_conf, dump_conf(cur, GLOBAL_FIELDS))
        self.request_reload(cur)

    def list_projects(self) -> list[dict[str, str]]:
        self.projects_dir.mkdir(parents=True, exist_ok=True)
        out = []
        for p in sorted(self.projects_dir.glob("*.conf")):
            d = parse_conf(p.read_text(encoding="utf-8"))
            d.setdefault("NAME", p.stem)
            d["_file"] = p.name
            out.append(d)
        return out

    def project_path(self, name: str) -> Path:
        return self.projects_dir / f"{name}.conf"

    def read_project(self, name: str) -> dict[str, str] | None:
        path = self.project_path(name)
        if not path.is_file():
            # try match NAME inside files
            for p in self.projects_dir.glob("*.conf"):
                d = parse_conf(p.read_text(encoding="utf-8"))
                if d.get("NAME") == name or p.stem == name:
                    d.setdefault("NAME", p.stem)
                    return d
            return None
        d = parse_conf(path.read_text(encoding="utf-8"))
        d.setdefault("NAME", name)
        return d

    def write_project(self, name: str, data: dict[str, str], create: bool = False) -> None:
        if not NAME_RE.match(name):
            raise ValueError("invalid NAME")
        path = self.project_path(name)
        if create and path.is_file():
            raise ValueError("project exists")
        if not create and not path.is_file():
            # allow update via NAME when file is name.conf
            if not path.is_file():
                raise ValueError("project not found")
        cur = parse_conf(path.read_text(encoding="utf-8")) if path.is_file() else {}
        cur.update({k: str(v) for k, v in data.items() if not str(k).startswith("_") and v is not None})
        cur["NAME"] = name
        atomic_write(path, dump_conf(cur, PROJECT_FIELDS))
        self.request_reload(self.read_global())

    def delete_project(self, name: str) -> None:
        path = self.project_path(name)
        if not path.is_file():
            raise ValueError("project not found")
        path.unlink()
        self.request_reload(self.read_global())

    def request_reload(self, global_cfg: dict[str, str] | None = None) -> None:
        cfg = global_cfg or self.read_global()
        data_dir = cfg.get("DATA_DIR") or str(self.root / "data")
        if not data_dir.startswith("/"):
            data_dir = str(self.root / data_dir)
        Path(data_dir).mkdir(parents=True, exist_ok=True)
        (Path(data_dir) / "reload.request").write_text(str(int(__import__("time").time())), encoding="utf-8")
        pid_file = Path(cfg.get("PID_FILE") or self.daemon_pid_file)
        if not str(pid_file).startswith("/"):
            pid_file = self.root / pid_file
        try:
            if pid_file.is_file():
                pid = int(pid_file.read_text(encoding="utf-8").strip())
                os.kill(pid, signal.SIGHUP)
        except (OSError, ValueError):
            pass


def make_handler(app: App, token: str, bind: str):
    class Handler(BaseHTTPRequestHandler):
        def _check_auth(self) -> bool:
            if bind in ("127.0.0.1", "localhost", "::1") and not token:
                return True
            if not token:
                self._json(403, {"error": "ADMIN_TOKEN required when not binding localhost"})
                return False
            got = self.headers.get("X-Admin-Token") or ""
            if got != token:
                # also allow ?token=
                q = urlparse(self.path).query
                if f"token={token}" not in q.split("&") and not any(
                    p == f"token={token}" for p in q.split("&")
                ):
                    self._json(401, {"error": "unauthorized"})
                    return False
            return True

        def _json(self, code: int, obj) -> None:
            body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
            self.send_response(code)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def _read_json(self) -> dict:
            n = int(self.headers.get("Content-Length") or 0)
            raw = self.rfile.read(n) if n else b"{}"
            return json.loads(raw.decode("utf-8") or "{}")

        def _serve_static(self, rel: str) -> None:
            if rel in ("", "/"):
                rel = "/index.html"
            path = (app.admin_ui / rel.lstrip("/")).resolve()
            if not str(path).startswith(str(app.admin_ui.resolve())):
                self.send_error(403)
                return
            if not path.is_file():
                self.send_error(404)
                return
            data = path.read_bytes()
            ctype = "text/plain"
            if path.suffix == ".html":
                ctype = "text/html; charset=utf-8"
            elif path.suffix == ".js":
                ctype = "application/javascript; charset=utf-8"
            elif path.suffix == ".css":
                ctype = "text/css; charset=utf-8"
            self.send_response(200)
            self.send_header("Content-Type", ctype)
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def do_GET(self):  # noqa: N802
            if not self._check_auth():
                return
            parsed = urlparse(self.path)
            path = parsed.path
            if path == "/api/config":
                self._json(
                    200,
                    {
                        "global": app.read_global(),
                        "projects": app.list_projects(),
                        "schema": {"global": GLOBAL_FIELDS, "project": PROJECT_FIELDS},
                    },
                )
                return
            if path.startswith("/api/projects/"):
                name = path[len("/api/projects/") :].strip("/")
                proj = app.read_project(name)
                if not proj:
                    self._json(404, {"error": "not found"})
                    return
                self._json(200, proj)
                return
            if path.startswith("/api/"):
                self._json(404, {"error": "not found"})
                return
            self._serve_static(path)

        def do_PUT(self):  # noqa: N802
            if not self._check_auth():
                return
            parsed = urlparse(self.path)
            path = parsed.path
            try:
                data = self._read_json()
            except json.JSONDecodeError:
                self._json(400, {"error": "invalid json"})
                return
            try:
                if path == "/api/global":
                    app.write_global(data)
                    self._json(200, {"ok": True, "global": app.read_global()})
                    return
                if path.startswith("/api/projects/"):
                    name = path[len("/api/projects/") :].strip("/")
                    app.write_project(name, data, create=False)
                    self._json(200, {"ok": True, "project": app.read_project(name)})
                    return
            except ValueError as e:
                self._json(400, {"error": str(e)})
                return
            self._json(404, {"error": "not found"})

        def do_POST(self):  # noqa: N802
            if not self._check_auth():
                return
            parsed = urlparse(self.path)
            if parsed.path != "/api/projects":
                self._json(404, {"error": "not found"})
                return
            try:
                data = self._read_json()
            except json.JSONDecodeError:
                self._json(400, {"error": "invalid json"})
                return
            name = str(data.get("NAME") or "").strip()
            try:
                app.write_project(name, data, create=True)
                self._json(201, {"ok": True, "project": app.read_project(name)})
            except ValueError as e:
                self._json(400, {"error": str(e)})

        def do_DELETE(self):  # noqa: N802
            if not self._check_auth():
                return
            parsed = urlparse(self.path)
            path = parsed.path
            if not path.startswith("/api/projects/"):
                self._json(404, {"error": "not found"})
                return
            name = path[len("/api/projects/") :].strip("/")
            try:
                app.delete_project(name)
                self._json(200, {"ok": True})
            except ValueError as e:
                self._json(400, {"error": str(e)})

        def log_message(self, fmt, *args):  # noqa: A003
            sys_stderr = __import__("sys").stderr
            sys_stderr.write("%s - %s\n" % (self.address_string(), fmt % args))

    return Handler


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", required=True)
    ap.add_argument("--bind", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--token", default="")
    ap.add_argument("--pid-file", default="")
    ap.add_argument("--daemon-pid-file", default="")
    args = ap.parse_args()
    root = Path(args.root).resolve()
    if args.bind not in ("127.0.0.1", "localhost", "::1") and not args.token:
        raise SystemExit("ADMIN_TOKEN required when ADMIN_BIND is not localhost")
    app = App(root, args.token, Path(args.daemon_pid_file or root / "data" / "watchci.pid"))
    handler = make_handler(app, args.token, args.bind)
    server = ThreadingHTTPServer((args.bind, args.port), handler)
    if args.pid_file:
        Path(args.pid_file).write_text(str(os.getpid()) + "\n", encoding="utf-8")
    print(f"WatchCI admin UI http://{args.bind}:{args.port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        if args.pid_file:
            try:
                os.unlink(args.pid_file)
            except OSError:
                pass


if __name__ == "__main__":
    main()
