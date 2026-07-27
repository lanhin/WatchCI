# WatchCI

本地常驻 CI 监听器：按配置轮询远程仓库分支 / PR，运行脚本，生成可推送的静态结果看板；提供本机网页管理配置。

## 依赖

- bash 4+、git、curl、flock、timeout、python3
- jq（平台 PR API）

## 快速开始

```bash
cp config/watchci.conf.example config/watchci.conf
# 编辑 config/projects/*.conf，设置 REPO_URL / OWNER / REPO / SCRIPT，ENABLED=true
export GITHUB_TOKEN=...   # 或对应 TOKEN_ENV

./bin/watchci start          # 前台常驻；间隔见 POLL_INTERVAL_SEC
# 另开终端
./bin/watchci status
./bin/watchci ui             # 仅配置页 http://127.0.0.1:8787/
```

`start` 且 `ADMIN_ENABLE=true` 时会同时拉起配置 UI。

## 命令

| 命令 | 说明 |
|------|------|
| `start` | 常驻 poll → run → sleep |
| `stop` | 停止 |
| `status` | 状态 |
| `ui` | 配置管理网页 |
| `tick` | 调试：跑一轮 |
| `publish` | 执行 `PUBLISH_CMD` 推送 `SITE_DIR` |
| `rebuild-site` | 按已有 run 重建看板 |

## 配置要点

- **全局** `config/watchci.conf`：轮询间隔、默认超时、看板发布、本机配置 UI。
- **项目** `config/projects/*.conf`：仓库、监听分支/PR、CI 脚本；超时未写则用全局 `DEFAULT_TIMEOUT_SEC`。
- **令牌**：项目里只写环境变量名（`TOKEN_ENV`），令牌本身放在环境变量中。
- 轮询间隔只有全局一份；项目 conf 里即使写了 `POLL_INTERVAL_SEC` 也不会生效。
- 字段说明见示例 conf 行注释，或本机配置 UI（中文标签 + 英文键名提示）。

## 两类网页

1. **结果看板** `data/site/` — 纯静态，可用 rsync/OSS 推公网。
2. **配置 UI** — 仅本机（默认 `127.0.0.1:8787`），不要随看板发布。

## 自检

```bash
./tests/smoke.sh
```

## Webhook

见 [hooks/README.md](hooks/README.md)。主路径仍是配置间隔轮询，不用 cron。
