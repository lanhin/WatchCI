# 把测试结果自动发到 PR 评论区

WatchCI 跑完一次 **PR** 测试后，可以在对应 Pull Request 的评论区留下（或更新）一条结果摘要。同一条 PR 只会维护**一条** WatchCI 评论：下次再跑会改这条，而不是刷屏。

支持平台：**GitHub**、**Gitee**、**GitCode**（暂不支持 GitLab）。

---

## 要不要「登录」？

**不用在 WatchCI 里登录。** 程序不会打开浏览器，也不会要你输入密码。

需要做的是：在 GitHub / Gitee / GitCode **网站上**，用**你自己的账号**创建一个「个人访问令牌」（Token），把令牌放到电脑的环境变量里。WatchCI 用这个令牌调用平台 API，**以你的账号名义**发评论（别人会看到是你的账号在说话）。

请保证：

1. 这个账号有权在目标仓库的 PR 下评论（自己的仓，或被加为协作者 / 有写权限的组织仓）。
2. 令牌勾选了**写评论**相关权限（只读令牌不够）。
3. **不要把令牌写进配置文件**；配置里只写环境变量的**名字**（例如 `TOKEN_ENV=GITHUB_TOKEN`）。

---

## 开始前准备

- 已经能用 WatchCI 轮询并跑通某个项目的 PR（`WATCH_PRS=true`）。
- （可选）看板已发布到公网，并知道根地址，例如 `https://ci.example.com`（不要末尾斜杠）。填了才能在评论里点开详情页。

---

## 一、在网站上创建令牌

下面任选你用的平台。创建后**立刻复制**令牌（很多网站只显示一次）。

### GitHub

1. 打开 GitHub → 右上角头像 → **Settings**。
2. 左侧最下方 **Developer settings** → **Personal access tokens**。
3. 选一种：
   - **Fine-grained token**：选目标仓库；Permissions 里给 **Issues**、**Pull requests** 至少 **Read and write**（评论走 Issues 评论接口）。
   - **Classic token**：私有仓勾选 **`repo`**；若只要公开仓，至少勾选能读写 Issues 的权限（例如 `public_repo` / 相关 issue 写权限，以页面为准）。
4. 生成后复制，在**启动 WatchCI 的那个终端**执行：

```bash
export GITHUB_TOKEN=ghp_你的令牌
```

### Gitee

1. 打开 Gitee → 右上角头像 → **设置**。
2. 左侧 **安全设置** → **私人令牌**（文案可能略有不同）。
3. 新建令牌，勾选与仓库、PR、评论相关的权限。常见需要勾选：**`projects`**（仓库）、**`pull_requests`**、**`issues`**、**`notes`**（评论）。页面选项若改名，原则是：**能读 PR，并能发 Issue/PR 评论**。
4. 复制令牌后：

```bash
export GITEE_TOKEN=你的令牌
```

### GitCode

1. 打开 GitCode → 进入账号 **设置 / 安全 / 个人访问令牌**（入口名称可能调整）。
2. 新建令牌，勾选能访问目标仓库，并允许读写 Issue / Pull Request / 评论。
3. 复制后：

```bash
export GITCODE_TOKEN=你的令牌
```

---

## 二、在 WatchCI 里怎么配

可用本机配置页 `./bin/watchci ui`，或直接改 conf。

### 项目配置（`config/projects/你的项目.conf`）

| 配置项 | 填什么 |
|--------|--------|
| `TOKEN_ENV` | 环境变量**名**，如 `GITHUB_TOKEN` / `GITEE_TOKEN` / `GITCODE_TOKEN`（不是令牌字符串本身） |
| `WATCH_PRS` | `true` |
| `POST_PR_COMMENT` | `true`（打开后才会回写评论，默认是关的） |
| `PROVIDER` | `github` / `gitee` / `gitcode` |

### 全局配置（可选，`config/watchci.conf`）

| 配置项 | 填什么 |
|--------|--------|
| `SITE_PUBLIC_URL` | 看板公网根地址，如 `https://ci.example.com`（**不要**末尾 `/`） |

示例片段：

```bash
# 全局
SITE_PUBLIC_URL=https://ci.example.com

# 项目
TOKEN_ENV=GITHUB_TOKEN
WATCH_PRS=true
POST_PR_COMMENT=true
```

### 重要：令牌要在「跑守护进程」的环境里

`export` 只对当前终端有效。用 `./bin/watchci start`、tmux、nohup、systemd、crontab 时，都要保证进程能读到同一个环境变量，否则评论会失败（WatchCI 只会打警告，不会把整次 CI 判失败）。

---

## 三、怎么确认成功

1. 开一个测试 PR（合入目标分支要在项目的 `BRANCHES` 里）。
2. 等 WatchCI 跑完（或 `./bin/watchci tick` 调试）。
3. 打开该 PR 的评论区，应看到一条带状态图标的摘要（✅ success / ❌ failure / ⏰ timeout）。
4. 再推一个 commit 触发第二次跑：应是**同一条评论内容被更新**，而不是又多一条新评论。

若填了 `SITE_PUBLIC_URL`，评论里会有「详情」链接，指向 `…/runs/<run_id>/`。

---

## 四、常见问题

| 现象 | 可能原因 |
|------|----------|
| 完全没有评论 | `POST_PR_COMMENT` 未开；或这次不是 PR 事件（分支推送不会评论） |
| 403 / 日志里 pr comment failed | 令牌权限不够，或账号对仓库没有评论权限 |
| 有评论但没有详情链接 | 未设置 `SITE_PUBLIC_URL` |
| 令牌写进了 `.conf` | 请删掉，改成只写 `TOKEN_ENV=变量名`，令牌只放环境变量 |
| 用 GitLab | 本功能暂不支持，会跳过并告警 |

更多后台说明见仓库 [README.md](../README.md)。
