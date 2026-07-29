#!/usr/bin/env python3
"""Local config admin HTTP server for WatchCI (stdlib only)."""
from __future__ import annotations

import argparse
import json
import os
import random
import re
import signal
import tempfile
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

NAME_RE = re.compile(r"^[A-Za-z0-9_-]+$")
LOG_NAME_RE = re.compile(r"^[A-Za-z0-9_.-]+\.log$")
RUN_ID_RE = re.compile(r"^[A-Za-z0-9_.-]+$")
FINISHED_MARK = "=== finished "
RERUN_STATUSES = frozenset({"failure", "timeout"})


# group id (internal) -> Chinese label for UI
GROUP_LABELS = {
    "runtime": "运行",
    "site": "看板发布",
    "paths": "路径（高级）",
    "admin": "本机管理",
    "identity": "仓库",
    "watch": "监听",
    "run": "执行",
}

# {key, label, help, group} — single source for UI + dump_conf comments
GLOBAL_SCHEMA = [
    {
        "key": "POLL_INTERVAL_SEC",
        "label": "轮询间隔（秒）",
        "help": "主循环间隔。所有项目共用。",
        "group": "runtime",
    },
    {
        "key": "MAX_PARALLEL_RUNS",
        "label": "每轮最多处理事件数",
        "help": "每 tick 最多处理的 pending 条数；仍串行，并非真正并行。",
        "group": "runtime",
    },
    {
        "key": "DEFAULT_TIMEOUT_SEC",
        "label": "默认超时（秒）",
        "help": "项目未设 TIMEOUT_SEC 时使用。",
        "group": "runtime",
    },
    {
        "key": "SITE_DIR",
        "label": "看板目录",
        "help": "静态结果看板输出目录；空则 data/site。",
        "group": "site",
    },
    {
        "key": "PUBLISH_CMD",
        "label": "发布命令",
        "help": "推送看板时执行的 shell 命令（在 SITE_DIR 下执行，源路径用 ./）；空则不发布。",
        "group": "site",
    },
    {
        "key": "AUTO_PUBLISH",
        "label": "自动发布",
        "help": "每次 run 结束更新看板后是否自动执行发布命令（rebuild-site 不会触发）。",
        "group": "site",
    },
    {
        "key": "DATA_DIR",
        "label": "数据目录",
        "help": "克隆、日志、状态等运行时数据；空则仓库下 data/。",
        "group": "paths",
    },
    {
        "key": "PID_FILE",
        "label": "守护进程 PID 文件",
        "help": "空则 data/watchci.pid。",
        "group": "paths",
    },
    {
        "key": "LOG_FILE",
        "label": "守护进程日志",
        "help": "空则 data/watchci.log；配置 UI 日志为同路径加 .admin。",
        "group": "paths",
    },
    {
        "key": "ADMIN_PID_FILE",
        "label": "配置 UI PID 文件",
        "help": "空则 data/watchci-admin.pid。",
        "group": "paths",
    },
    {
        "key": "ADMIN_ENABLE",
        "label": "随守护进程启动配置 UI",
        "help": "start 时是否后台拉起本机配置页。",
        "group": "admin",
    },
    {
        "key": "ADMIN_BIND",
        "label": "配置 UI 监听地址",
        "help": "默认 127.0.0.1（仅本机）。非本机须设访问令牌。",
        "group": "admin",
    },
    {
        "key": "ADMIN_PORT",
        "label": "配置 UI 端口",
        "help": "默认 8787。",
        "group": "admin",
    },
    {
        "key": "ADMIN_TOKEN",
        "label": "配置 UI 访问令牌",
        "help": "请求头 X-Admin-Token 或 ?token=；本机可空。",
        "group": "admin",
    },
]

PROJECT_SCHEMA = [
    {
        "key": "NAME",
        "label": "项目名称",
        "help": "字母数字与下划线、短横线；通常与文件名一致。",
        "group": "identity",
    },
    {
        "key": "ENABLED",
        "label": "启用",
        "help": "否时跳过该项目。",
        "group": "identity",
    },
    {
        "key": "PROVIDER",
        "label": "代码托管平台",
        "help": "github / gitee / gitlab / gitcode。",
        "group": "identity",
    },
    {
        "key": "REPO_URL",
        "label": "Git 远程地址",
        "help": "用于 clone / fetch，必填。",
        "group": "identity",
    },
    {
        "key": "API_BASE",
        "label": "API 根地址",
        "help": "空则用平台默认（如 https://api.github.com）。",
        "group": "identity",
    },
    {
        "key": "OWNER",
        "label": "仓库所有者",
        "help": "平台上的 owner/org；查 PR 等 API 时需要。",
        "group": "identity",
    },
    {
        "key": "REPO",
        "label": "仓库名",
        "help": "平台短名（非完整 URL）。",
        "group": "identity",
    },
    {
        "key": "PROJECT_ID",
        "label": "GitLab 项目 ID",
        "help": "仅 GitLab 需要；其它平台留空。",
        "group": "identity",
    },
    {
        "key": "BRANCHES",
        "label": "监听分支",
        "help": "逗号分隔；空则按 main。推送与 PR 合入目标均按此过滤。",
        "group": "watch",
    },
    {
        "key": "WATCH_PRS",
        "label": "监听 PR/MR",
        "help": "是否轮询拉取请求。",
        "group": "watch",
    },
    {
        "key": "PR_LABELS",
        "label": "PR 标签过滤",
        "help": "仅 GitHub：逗号分隔；空表示不过滤。",
        "group": "watch",
    },
    {
        "key": "SCRIPT",
        "label": "CI 脚本",
        "help": "相对仓库根或绝对路径；必填。",
        "group": "run",
    },
    {
        "key": "WORKDIR",
        "label": "工作目录",
        "help": "相对克隆根；空则在克隆根执行。",
        "group": "run",
    },
    {
        "key": "TIMEOUT_SEC",
        "label": "超时（秒）",
        "help": "空则用全局默认超时。",
        "group": "run",
    },
    {
        "key": "ALLOW_MANUAL_RERUN",
        "label": "允许手动重跑失败",
        "help": "本机台是否可对失败/超时的 run 一键重跑（同 SHA 再入队）。",
        "group": "run",
    },
    {
        "key": "TOKEN_ENV",
        "label": "令牌环境变量名",
        "help": "如 GITHUB_TOKEN；存的是变量名，不是令牌本身。",
        "group": "run",
    },
    {
        "key": "CLONE_DIR",
        "label": "克隆目录",
        "help": "空则 data/clones/<项目名>。",
        "group": "paths",
    },
]

GLOBAL_FIELDS = [f["key"] for f in GLOBAL_SCHEMA]
PROJECT_FIELDS = [f["key"] for f in PROJECT_SCHEMA]


def dump_conf(data: dict[str, str], schema: list[dict]) -> str:
    """Write KEY=value with Chinese comments from schema; group breaks as blank lines."""
    lines = ["# 由 WatchCI 配置界面管理", ""]
    seen: set[str] = set()
    prev_group: str | None = None
    for field in schema:
        k = field["key"]
        if k not in data:
            continue
        if prev_group is not None and field["group"] != prev_group:
            lines.append("")
        prev_group = field["group"]
        label = field.get("label") or k
        help_ = field.get("help") or ""
        lines.append(f"# {label} — {help_}" if help_ else f"# {label}")
        lines.append(f"{k}={data[k]}")
        seen.add(k)
    extras = [(k, v) for k, v in data.items() if k not in seen and not str(k).startswith("_")]
    if extras:
        lines.append("")
        lines.append("# 未在 schema 中的项")
        for k, v in extras:
            lines.append(f"{k}={v}")
    lines.append("")
    return "\n".join(lines)


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
                atomic_write(self.global_conf, dump_conf({}, GLOBAL_SCHEMA))

    def read_global(self) -> dict[str, str]:
        self.ensure_global()
        return parse_conf(self.global_conf.read_text(encoding="utf-8"))

    def write_global(self, data: dict[str, str]) -> None:
        cur = self.read_global()
        cur.update({k: str(v) for k, v in data.items() if v is not None})
        # drop removed project-poll key if somehow present in global write payload
        atomic_write(self.global_conf, dump_conf(cur, GLOBAL_SCHEMA))
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
            raise ValueError("项目名称无效（仅字母数字、下划线、短横线）")
        path = self.project_path(name)
        if create and path.is_file():
            raise ValueError("项目已存在")
        if not create and not path.is_file():
            raise ValueError("项目不存在")
        cur = parse_conf(path.read_text(encoding="utf-8")) if path.is_file() else {}
        cur.update({k: str(v) for k, v in data.items() if not str(k).startswith("_") and v is not None})
        cur.pop("POLL_INTERVAL_SEC", None)  # dead project key; never rewrite
        cur["NAME"] = name
        atomic_write(path, dump_conf(cur, PROJECT_SCHEMA))
        self.request_reload(self.read_global())

    def delete_project(self, name: str) -> None:
        path = self.project_path(name)
        if not path.is_file():
            raise ValueError("项目不存在")
        path.unlink()
        self.request_reload(self.read_global())

    def data_dir(self, global_cfg: dict[str, str] | None = None) -> Path:
        cfg = global_cfg or self.read_global()
        data_dir = cfg.get("DATA_DIR") or str(self.root / "data")
        p = Path(data_dir)
        if not p.is_absolute():
            p = self.root / p
        return p.resolve()

    def request_reload(self, global_cfg: dict[str, str] | None = None) -> None:
        cfg = global_cfg or self.read_global()
        data_dir = self.data_dir(cfg)
        data_dir.mkdir(parents=True, exist_ok=True)
        (data_dir / "reload.request").write_text(str(int(time.time())), encoding="utf-8")
        pid_file = Path(cfg.get("PID_FILE") or self.daemon_pid_file)
        if not str(pid_file).startswith("/"):
            pid_file = self.root / pid_file
        try:
            if pid_file.is_file():
                pid = int(pid_file.read_text(encoding="utf-8").strip())
                os.kill(pid, signal.SIGHUP)
        except (OSError, ValueError):
            pass

    def daemon_running(self, global_cfg: dict[str, str] | None = None) -> bool:
        cfg = global_cfg or self.read_global()
        pid_file = Path(cfg.get("PID_FILE") or self.daemon_pid_file)
        if not pid_file.is_absolute():
            pid_file = self.root / pid_file
        try:
            if not pid_file.is_file():
                return False
            pid = int(pid_file.read_text(encoding="utf-8").strip())
            os.kill(pid, 0)
            return True
        except (OSError, ValueError):
            return False

    def _log_run_id(self, path: Path) -> str:
        stem = path.stem
        return stem.rsplit("-", 1)[0] if "-" in stem else stem

    def _log_finished(self, path: Path, data_dir: Path | None = None) -> bool:
        # Meta is authoritative: after timeout, orphan children can keep appending and
        # bury "=== finished" past any fixed tail window.
        run_id = self._log_run_id(path)
        if RUN_ID_RE.match(run_id):
            meta = (data_dir or self.data_dir()) / "runs" / f"{run_id}.meta.json"
            if meta.is_file():
                return True
        try:
            size = path.stat().st_size
            with path.open("rb") as f:
                # 64KiB covers post-timeout ctest spill; still cheap
                window = min(size, 65536)
                if size > window:
                    f.seek(size - window)
                tail = f.read().decode("utf-8", errors="replace")
            return FINISHED_MARK in tail
        except OSError:
            return True

    def _parse_log_header(self, path: Path) -> dict[str, str]:
        out: dict[str, str] = {}
        try:
            with path.open("r", encoding="utf-8", errors="replace") as f:
                for i, line in enumerate(f):
                    if i > 12:
                        break
                    s = line.strip()
                    if s.startswith("project=") and " kind=" in s:
                        for part in s.split():
                            if "=" in part:
                                k, v = part.split("=", 1)
                                out[k] = v
                    elif s.startswith("started="):
                        out["started"] = s.split("=", 1)[1]
                    elif s.startswith("timeout_sec="):
                        out["timeout_sec"] = s.split("=", 1)[1]
        except OSError:
            pass
        return out

    def _parse_finished_line(self, path: Path) -> dict[str, str]:
        """Pull status/duration/timeout from finished marker (last 64KiB)."""
        out: dict[str, str] = {}
        try:
            size = path.stat().st_size
            with path.open("rb") as f:
                window = min(size, 65536)
                if size > window:
                    f.seek(size - window)
                tail = f.read().decode("utf-8", errors="replace")
            for line in reversed(tail.splitlines()):
                s = line.strip()
                if not s.startswith(FINISHED_MARK):
                    continue
                # === finished status=X exit=N duration=Ys timeout_sec=Z ===
                body = s[len(FINISHED_MARK) :].rstrip("=").strip()
                for part in body.split():
                    if "=" in part:
                        k, v = part.split("=", 1)
                        out[k] = v.rstrip("s") if k == "duration" and v.endswith("s") else v
                break
        except OSError:
            pass
        return out

    def _run_meta_path(self, run_id: str, data_dir: Path | None = None) -> Path:
        return (data_dir or self.data_dir()) / "runs" / f"{run_id}.meta.json"

    def live_snapshot(self) -> dict:
        cfg = self.read_global()
        data = self.data_dir(cfg)
        pending_dir = data / "events" / "pending"
        pending = sorted(p.name for p in pending_dir.glob("*.json")) if pending_dir.is_dir() else []
        active = []
        logs_root = data / "logs"
        if logs_root.is_dir():
            for proj_dir in sorted(logs_root.iterdir()):
                if not proj_dir.is_dir() or not NAME_RE.match(proj_dir.name):
                    continue
                for log in sorted(proj_dir.glob("*.log"), key=lambda p: p.stat().st_mtime, reverse=True):
                    if not LOG_NAME_RE.match(log.name):
                        continue
                    if self._log_finished(log, data):
                        continue
                    run_id = self._log_run_id(log)
                    st = log.stat()
                    hdr = self._parse_log_header(log)
                    active.append(
                        {
                            "project": proj_dir.name,
                            "file": log.name,
                            "run_id": run_id,
                            "size": st.st_size,
                            "mtime": int(st.st_mtime),
                            "kind": hdr.get("kind", ""),
                            "ref": hdr.get("ref", ""),
                            "pr_id": hdr.get("pr_id", ""),
                            "sha": hdr.get("sha", ""),
                            "started": hdr.get("started", ""),
                            "timeout_sec": hdr.get("timeout_sec", ""),
                        }
                    )
        active.sort(key=lambda r: r["mtime"], reverse=True)
        locks = []
        state_dir = data / "state"
        if state_dir.is_dir():
            for d in sorted(state_dir.glob("*.lockdir")):
                if d.is_dir():
                    locks.append(d.name[: -len(".lockdir")])
        return {
            "daemon": "running" if self.daemon_running(cfg) else "stopped",
            "pending": len(pending),
            "pending_ids": pending[:20],
            "locks": locks,
            "active": active,
            "ts": int(time.time()),
        }

    def tail_run_log(self, project: str, name: str, offset: int) -> dict:
        if not NAME_RE.match(project) or not LOG_NAME_RE.match(name):
            raise ValueError("无效的日志路径")
        path = (self.data_dir() / "logs" / project / name).resolve()
        logs_root = (self.data_dir() / "logs").resolve()
        if not str(path).startswith(str(logs_root) + os.sep):
            raise ValueError("无效的日志路径")
        if not path.is_file():
            raise FileNotFoundError("日志不存在")
        size = path.stat().st_size
        if offset < 0:
            offset = 0
        if offset > size:
            offset = size
        with path.open("rb") as f:
            f.seek(offset)
            chunk = f.read(256 * 1024)
        text = chunk.decode("utf-8", errors="replace")
        hdr = self._parse_log_header(path)
        done = self._log_finished(path)
        out: dict = {
            "project": project,
            "file": name,
            "offset": offset,
            "next_offset": offset + len(chunk),
            "size": size,
            "text": text,
            "done": done,
            "started": hdr.get("started", ""),
            "timeout_sec": hdr.get("timeout_sec", ""),
        }
        if done:
            run_id = self._log_run_id(path)
            meta_path = self._run_meta_path(run_id)
            meta: dict = {}
            if meta_path.is_file():
                try:
                    meta = json.loads(meta_path.read_text(encoding="utf-8"))
                except (OSError, json.JSONDecodeError):
                    meta = {}
            fin = self._parse_finished_line(path)
            if meta.get("duration") is not None:
                out["duration"] = meta["duration"]
            elif fin.get("duration") is not None:
                try:
                    out["duration"] = int(fin["duration"])
                except ValueError:
                    out["duration"] = fin["duration"]
            out["status"] = str(meta.get("status") or fin.get("status") or "")
            to = meta.get("timeout_sec")
            if to is not None and to != "":
                out["timeout_sec"] = str(to)
            elif fin.get("timeout_sec"):
                out["timeout_sec"] = fin["timeout_sec"]
        return out

    def _read_run_meta(self, run_id: str) -> dict:
        if not RUN_ID_RE.match(run_id):
            raise ValueError("无效的 run id")
        path = self.data_dir() / "runs" / f"{run_id}.meta.json"
        if not path.is_file():
            raise FileNotFoundError("run 不存在")
        try:
            return json.loads(path.read_text(encoding="utf-8"))
        except json.JSONDecodeError as e:
            raise ValueError("run meta 无效") from e

    def _delete_run_files(self, run_id: str, meta: dict) -> None:
        meta_path = self.data_dir() / "runs" / f"{run_id}.meta.json"
        try:
            meta_path.unlink(missing_ok=True)
        except OSError:
            pass
        log = Path(str(meta.get("log") or ""))
        if log.is_file():
            try:
                log.unlink()
            except OSError:
                pass

    def _tracked_sha(self, project: str, kind: str, key: str) -> str:
        """Current head sha from state.tsv for kind+key (pr id or branch name)."""
        if not project or not key:
            return ""
        sf = self.data_dir() / "state" / f"{project}.tsv"
        if not sf.is_file():
            return ""
        try:
            text = sf.read_text(encoding="utf-8")
        except OSError:
            return ""
        for line in text.splitlines():
            parts = line.split("\t")
            if len(parts) >= 3 and parts[0] == kind and parts[1] == key:
                return parts[2]
        return ""

    def _run_track_key(self, meta: dict) -> tuple[str, str]:
        """Return (state_kind, state_key) for a run meta."""
        kind = str(meta.get("kind") or "branch")
        if kind == "pr":
            pr = meta.get("pr_id")
            if pr not in (None, ""):
                return "pr", str(pr)
        return "branch", str(meta.get("ref") or "")

    def _delete_matching_failures(self, meta: dict) -> None:
        """Drop this failure and duplicates for the same checkout (leaves rerun list)."""
        project = str(meta.get("project") or "")
        kind = str(meta.get("kind") or "")
        ref = str(meta.get("ref") or "")
        sha = str(meta.get("sha") or "")
        pr_key = "" if meta.get("pr_id") in (None, "") else str(meta.get("pr_id"))
        runs_dir = self.data_dir() / "runs"
        if not runs_dir.is_dir() or not project or not sha:
            return
        for path in list(runs_dir.glob("*.meta.json")):
            try:
                m = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if str(m.get("status") or "") not in RERUN_STATUSES:
                continue
            if str(m.get("project") or "") != project:
                continue
            if str(m.get("kind") or "") != kind:
                continue
            if str(m.get("ref") or "") != ref:
                continue
            if str(m.get("sha") or "") != sha:
                continue
            m_pr = "" if m.get("pr_id") in (None, "") else str(m.get("pr_id"))
            if m_pr != pr_key:
                continue
            rid = str(m.get("id") or path.name.removesuffix(".meta.json"))
            self._delete_run_files(rid, m)

    def list_runs(
        self,
        project: str = "",
        status: str = "",
        limit: int = 50,
    ) -> list[dict]:
        runs_dir = self.data_dir() / "runs"
        if not runs_dir.is_dir():
            return []
        want_status = {status} if status else set(RERUN_STATUSES)
        out: list[dict] = []
        for path in runs_dir.glob("*.meta.json"):
            try:
                meta = json.loads(path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            st = str(meta.get("status") or "")
            if st not in want_status:
                continue
            proj = str(meta.get("project") or "")
            if project and proj != project:
                continue
            sha = str(meta.get("sha") or "")
            if not sha:
                continue
            skind, skey = self._run_track_key(meta)
            tracked = self._tracked_sha(proj, skind, skey)
            # only current head; no state row → keep (orphan / tests)
            if tracked and sha != tracked:
                continue
            out.append(
                {
                    "id": meta.get("id") or path.name.removesuffix(".meta.json"),
                    "project": proj,
                    "kind": meta.get("kind") or "",
                    "ref": meta.get("ref") or "",
                    "pr_id": meta.get("pr_id"),
                    "sha": sha,
                    "status": st,
                    "exit_code": meta.get("exit_code"),
                    "started": meta.get("started"),
                    "finished": meta.get("finished"),
                    "duration": meta.get("duration"),
                }
            )
        out.sort(key=lambda r: int(r.get("finished") or 0), reverse=True)
        # one 重跑 row per PR/branch (latest head only)
        seen: set[tuple[str, str, str]] = set()
        deduped: list[dict] = []
        for r in out:
            pr = "" if r.get("pr_id") in (None, "") else str(r.get("pr_id"))
            if str(r.get("kind") or "") == "pr" and pr:
                key = (str(r.get("project") or ""), "pr", pr)
            else:
                key = (str(r.get("project") or ""), "branch", str(r.get("ref") or ""))
            if key in seen:
                continue
            seen.add(key)
            deduped.append(r)
        if limit < 1:
            limit = 50
        return deduped[:limit]

    def _pending_has_dup(self, pending_dir: Path, project: str, kind: str, ref: str, sha: str) -> bool:
        if not pending_dir.is_dir():
            return False
        for f in pending_dir.glob("*.json"):
            try:
                ev = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if (
                ev.get("project") == project
                and ev.get("kind") == kind
                and ev.get("ref") == ref
                and ev.get("sha") == sha
            ):
                return True
        return False

    def _drop_stale_pending(
        self,
        pending_dir: Path,
        project: str,
        kind: str,
        ref: str,
        sha: str,
        pr_id: str | None,
    ) -> None:
        """Mirror bash event_drop_stale_pending."""
        if not pending_dir.is_dir():
            return
        done_dir = self.data_dir() / "events" / "done"
        done_dir.mkdir(parents=True, exist_ok=True)
        for f in list(pending_dir.glob("*.json")):
            try:
                ev = json.loads(f.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            if ev.get("project") != project or ev.get("kind") != kind:
                continue
            if str(ev.get("sha") or "") in ("", sha):
                continue
            if kind == "pr":
                ev_pr = ev.get("pr_id")
                ev_pr_s = None if ev_pr in (None, "") else str(ev_pr)
                if ev_pr_s != pr_id:
                    continue
            else:
                if str(ev.get("ref") or "") != ref:
                    continue
            try:
                f.rename(done_dir / f.name)
            except OSError:
                try:
                    f.unlink()
                except OSError:
                    pass

    def enqueue_manual(
        self,
        project: str,
        kind: str,
        ref: str,
        sha: str,
        pr_id: str | None = None,
    ) -> dict:
        """Mirror bash event_enqueue; source=manual. Returns event_id or skipped."""
        pending_dir = self.data_dir() / "events" / "pending"
        pending_dir.mkdir(parents=True, exist_ok=True)
        self._drop_stale_pending(pending_dir, project, kind, ref, sha, pr_id)
        if self._pending_has_dup(pending_dir, project, kind, ref, sha):
            return {"ok": True, "skipped": "already_pending"}
        event_id = f"{int(time.time())}-{os.getpid()}-{random.randint(0, 32767)}"
        payload = {
            "project": project,
            "kind": kind,
            "ref": ref,
            "pr_id": pr_id if pr_id else None,
            "sha": sha,
            "source": "manual",
            "ts": int(time.time()),
        }
        atomic_write(pending_dir / f"{event_id}.json", json.dumps(payload, ensure_ascii=False) + "\n")
        return {"ok": True, "event_id": event_id}

    def rerun_run(self, run_id: str) -> dict:
        meta = self._read_run_meta(run_id)
        status = str(meta.get("status") or "")
        if status not in RERUN_STATUSES:
            raise ValueError("仅 failure / timeout 可重跑")
        project = str(meta.get("project") or "")
        if not project:
            raise ValueError("run 缺少 project")
        proj = self.read_project(project)
        if not proj:
            raise ValueError(f"找不到项目配置: {project}")
        allow = str(proj.get("ALLOW_MANUAL_RERUN", "true")).lower()
        if allow not in ("true", "1", "yes"):
            raise PermissionError("项目已关闭手动重跑（ALLOW_MANUAL_RERUN）")
        kind = str(meta.get("kind") or "branch")
        ref = str(meta.get("ref") or "")
        sha = str(meta.get("sha") or "")
        if not sha:
            raise ValueError("run 缺少 sha")
        pr_id = meta.get("pr_id")
        if pr_id is None or pr_id == "":
            pr_s = None
        else:
            pr_s = str(pr_id)
        skind, skey = self._run_track_key(meta)
        tracked = self._tracked_sha(project, skind, skey)
        if tracked and sha != tracked:
            raise ValueError("已过时，仅可重跑当前 head")
        result = self.enqueue_manual(project, kind, ref, sha, pr_s)
        result["run_id"] = run_id
        # ponytail: clear all matching failures (not only the clicked id)
        self._delete_matching_failures(meta)
        return result


def make_handler(app: App, token: str, bind: str):
    class Handler(BaseHTTPRequestHandler):
        def _check_auth(self) -> bool:
            if bind in ("127.0.0.1", "localhost", "::1") and not token:
                return True
            if not token:
                self._json(403, {"error": "非本机监听时必须设置访问令牌"})
                return False
            got = self.headers.get("X-Admin-Token") or ""
            if got != token:
                q = urlparse(self.path).query
                if f"token={token}" not in q.split("&") and not any(
                    p == f"token={token}" for p in q.split("&")
                ):
                    self._json(401, {"error": "未授权"})
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
            elif path.suffix == ".svg":
                ctype = "image/svg+xml"
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
            qs = parse_qs(parsed.query)
            if path == "/api/config":
                self._json(
                    200,
                    {
                        "global": app.read_global(),
                        "projects": app.list_projects(),
                        "schema": {
                            "global": GLOBAL_SCHEMA,
                            "project": PROJECT_SCHEMA,
                            "groups": GROUP_LABELS,
                        },
                    },
                )
                return
            if path == "/api/live":
                self._json(200, app.live_snapshot())
                return
            if path == "/api/runs":
                try:
                    limit = int((qs.get("limit") or ["50"])[0])
                except ValueError:
                    self._json(400, {"error": "limit 无效"})
                    return
                project = (qs.get("project") or [""])[0]
                status = (qs.get("status") or [""])[0]
                self._json(
                    200,
                    {
                        "runs": app.list_runs(
                            project=project,
                            status=status,
                            limit=limit,
                        )
                    },
                )
                return
            if path == "/api/live/tail":
                project = (qs.get("project") or [""])[0]
                name = (qs.get("file") or [""])[0]
                try:
                    offset = int((qs.get("offset") or ["0"])[0])
                except ValueError:
                    self._json(400, {"error": "offset 无效"})
                    return
                try:
                    self._json(200, app.tail_run_log(project, name, offset))
                except ValueError as e:
                    self._json(400, {"error": str(e)})
                except FileNotFoundError as e:
                    self._json(404, {"error": str(e)})
                return
            if path.startswith("/api/projects/"):
                name = path[len("/api/projects/") :].strip("/")
                proj = app.read_project(name)
                if not proj:
                    self._json(404, {"error": "未找到"})
                    return
                self._json(200, proj)
                return
            if path.startswith("/api/"):
                self._json(404, {"error": "未找到"})
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
                self._json(400, {"error": "无效的 JSON"})
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
            self._json(404, {"error": "未找到"})

        def do_POST(self):  # noqa: N802
            if not self._check_auth():
                return
            parsed = urlparse(self.path)
            path = parsed.path
            if path.startswith("/api/runs/") and path.endswith("/rerun"):
                run_id = path[len("/api/runs/") : -len("/rerun")].strip("/")
                try:
                    self._json(200, app.rerun_run(run_id))
                except FileNotFoundError as e:
                    self._json(404, {"error": str(e)})
                except PermissionError as e:
                    self._json(403, {"error": str(e)})
                except ValueError as e:
                    self._json(400, {"error": str(e)})
                return
            if path != "/api/projects":
                self._json(404, {"error": "未找到"})
                return
            try:
                data = self._read_json()
            except json.JSONDecodeError:
                self._json(400, {"error": "无效的 JSON"})
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
                self._json(404, {"error": "未找到"})
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
        raise SystemExit("非本机监听时必须设置 ADMIN_TOKEN")
    app = App(root, args.token, Path(args.daemon_pid_file or root / "data" / "watchci.pid"))
    handler = make_handler(app, args.token, args.bind)
    ThreadingHTTPServer.allow_reuse_address = True
    try:
        server = ThreadingHTTPServer((args.bind, args.port), handler)
    except OSError as e:
        raise SystemExit(f"无法绑定 {args.bind}:{args.port}: {e}") from e
    if args.pid_file:
        Path(args.pid_file).parent.mkdir(parents=True, exist_ok=True)
        Path(args.pid_file).write_text(str(os.getpid()) + "\n", encoding="utf-8")
    print(f"WatchCI 配置界面 http://{args.bind}:{args.port}/", flush=True)
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
