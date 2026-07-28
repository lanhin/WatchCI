# WatchCI

本地常驻 CI 监听器：按配置轮询远程仓库分支 / PR，运行脚本，生成可推送的静态结果看板；提供本机网页管理配置。

## 依赖

- bash 4+、git、curl、timeout、python3
- jq（平台 PR API）
- 推送看板若用 rsync，需本机（及 SSH 目标机）安装 rsync（可选）

## 快速开始

```bash
cp config/watchci.conf.example config/watchci.conf
cp config/projects/example.conf config/projects/my-app.conf
# 编辑 my-app.conf：REPO_URL / OWNER / REPO / SCRIPT，ENABLED=true
export GITHUB_TOKEN=...   # 对应项目 TOKEN_ENV 指向的环境变量名，勿把令牌写进 conf

./bin/watchci tick         # 可选：先跑一轮 poll+执行，再看 data/site/
./bin/watchci start        # 前台常驻；间隔见 POLL_INTERVAL_SEC（可用 nohup/tmux）
# 另开终端
./bin/watchci status
./bin/watchci ui           # 仅配置页 http://127.0.0.1:8787/
```

`start` 且 `ADMIN_ENABLE=true` 时会同时拉起配置 UI。字段说明见示例 conf 行注释，或本机配置 UI。

## 命令

| 命令 | 说明 |
|------|------|
| `start` | 前台 poll → run → sleep；`ADMIN_ENABLE=true` 时顺带起配置 UI |
| `stop` | 停止守护进程与配置 UI |
| `status` | 守护进程 / 配置 UI / 路径等状态 |
| `ui` | 仅配置 UI（前台）；与结果看板无关 |
| `tick` | 调试：一轮 poll + 排空 pending |
| `publish` | 在 `SITE_DIR` 下执行 `PUBLISH_CMD` 推送看板 |
| `rebuild-site` | 按已有 run 全量重建本地看板（不自动 publish） |

看板更新与发布细节见下节。

## 配置要点

- **全局** `config/watchci.conf`：轮询间隔、默认超时、看板发布、本机配置 UI。
- **项目** `config/projects/*.conf`：仓库、监听分支/PR、CI 脚本；超时未写则用全局 `DEFAULT_TIMEOUT_SEC`。
- **令牌**：项目里只写环境变量名（`TOKEN_ENV`），令牌本身放在环境变量中。
- 轮询间隔只有全局一份；项目 conf 里即使写了 `POLL_INTERVAL_SEC` 也不会生效。
- 字段说明见 `config/watchci.conf.example`、`config/projects/example.conf`，或本机配置 UI（中文标签 + 英文键名提示）。

## 结果看板

输出目录默认 `data/site/`（`SITE_DIR`）。纯静态 HTML，可推公网；**进行中的 run 不会出现在看板上**，只在 run **结束后**更新。

| 动作 | 时机 / 命令 | 效果 |
|------|-------------|------|
| 日常 | 每次 CI run **结束** | 自动重写 `SITE_DIR`；若 `AUTO_PUBLISH=true` 再执行 `PUBLISH_CMD` |
| 升级 / 改模板后 | `./bin/watchci rebuild-site` | 按已有 run **全量**重建本地看板；浏览器需强刷 |
| 推公网 | `./bin/watchci publish` | 执行 `PUBLISH_CMD`（与 `AUTO_PUBLISH` 独立） |

```bash
./bin/watchci rebuild-site   # 本地看板按最新模板重渲
./bin/watchci publish        # 需要时再推（依赖 PUBLISH_CMD）
```

改代码或模板 **不会**自动刷新已打开的 `file://.../data/site/index.html`；须 `rebuild-site`（或等下次 run 结束）后再强刷。

### 发布（`PUBLISH_CMD`）

`PUBLISH_CMD` 在 **`SITE_DIR` 目录下执行**（`cd` 到看板输出目录后再 `eval`）。命令里的源路径请用 `.` / `./`，不要写仓库相对路径如 `data/site`。

常用做法是 rsync 同步到远端目录：

```bash
# config/watchci.conf
# 在 SITE_DIR（默认 data/site）下执行，故源用 ./
PUBLISH_CMD='rsync -az --delete ./ user@host:/var/www/watchci/'
AUTO_PUBLISH=false
```

- **`--delete`**：远端与本地一致（会删掉本地已无的旧 run 页）；远端另有文件则去掉该选项。
- 只推结果看板，**不要**把本机配置 UI 算进发布目标。
- `rebuild-site` **不会**触发 `AUTO_PUBLISH`；重建后要上公网再跑一次 `publish`。
- 也可用 OSS CLI 或自定义脚本，只要能在 `SITE_DIR` 下跑通即可。

## 两类网页

1. **结果看板** `data/site/` — 见上节；可发布到公网。
2. **配置 UI** — 仅本机（默认 `127.0.0.1:8787`），不要随看板发布。内含：
   - **现场**：轮询跟进进行中的 run 日志（边跑边刷）
   - **可重跑**：失败 / 超时记录一键入队（项目 `ALLOW_MANUAL_RERUN`）
   - **全局 / 项目**：编辑 `config/*.conf`
   - 监听非本机地址时须设 `ADMIN_TOKEN`（请求头 `X-Admin-Token` 或 `?token=`）

## 自检

```bash
./tests/smoke.sh
```

## Webhook

见 [hooks/README.md](hooks/README.md)。Webhook 只把事件写入 pending 队列，仍靠守护进程或 `tick` 消费；主路径仍是配置间隔轮询，不用 cron。
