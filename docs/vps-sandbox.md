# 访客沙盒（公网开放的 opencode 实例）

VPS 上除了私有的 `pocket.{$DOMAIN}`（见 `docs/vps-opencode.md`），还有一套**公开可玩**的
opencode 沙盒：

- 入口子域：`code-sandbox.{$DOMAIN}`（无密码开放，匿名可玩）。
- 访客进站即落入**唯一一条固定会话**并锁定：隐藏主页/导航，不能选或新建会话、
  不能改设置、不能加项目、不能离开；只保留手机端右侧 `Session | Changes` 面板。
- 与本仓库的私有 pocket、以及博客主站，各自容器 / 网络 / 卷互不相通（仅两处刻意共享，见下）。

> 2026-10 起，沙盒的实现（源码 / CI / 部署 / 配置）**整体在本仓库**，与博客仓库
> `zxLumen-Blog` 解耦；博客侧只剩「TLS + 3 行转发」的 stub。本文件是唯一真相来源，
> 博客侧的 `docs/PLAYGROUND.md` 只是指向这里的指针。

## 目录（本仓库）

```
infra/vps/sandbox/
├── Dockerfile          # 沙盒镜像（基于 ghcr.io/anomalyco/opencode）
├── entrypoint.sh       # 每次启动把只读基准配置烤回家目录
├── opencode.json       # 基准配置（烤进镜像只读区，运行时改动重启即还原）
├── seed/               # 播种到工作区/家目录的助手说明与 README（仅缺失时写）
│   ├── AGENTS.md
│   └── README.md
├── Caddyfile           # 边缘 Caddy：code-sandbox 的全部「访客锁定」逻辑
├── docker-compose.yml  # 三服务：sandbox-caddy / opencode-play / opencode-play-init
├── deploy.sh           # 部署（拉镜像 → reload 边缘 Caddy → up -d → 回收旧镜像）
├── ci-run.sh           # 部署入口：先同步服务器侧配置，再交给 deploy.sh
├── auto-deploy.sh      # cron 轮询部署（见下）
└── .env.example        # 服务器 .env 模板（不入库）
.github/workflows/sandbox.yml   # CI：构建推送 ghcr.io/<owner>/opencode-pocket-sandbox:<sha>/latest
```

## 架构

```
访客浏览器
   │ https://code-sandbox.{$DOMAIN}
   ▼
博客栈 Caddy（占 80/443，只做 TLS + 3 行转发）
   │ reverse_proxy sandbox-caddy:80 { flush_interval -1 }
   ▼
本次部署的 sandbox-caddy（边缘 Caddy，站点 :80）
   │ 访客锁定逻辑全在这里：文档请求只认唯一会话、其余 302 跳回；
   │ 写入白名单只放行该会话下的对话操作；pty/shell/tui 与 session/fork 全封；
   │ 其余 HTML 请求返回「自建外壳」（取二进制里的真 index.html，注入隐藏+守卫）
   ▼
docker_play 内网 ──► opencode-play 容器（opencode web :4096）
                          │ 只接 docker_play，其它子应用一律不可达
                          ├─ /workspace        ← named volume，访客共享目录（可写）
                          ├─ /home/opencode    ← named volume（会话 / 状态）
                          ├─ /tmp              ← tmpfs
                          └─ ZX_AI_APP_TOKEN → 博客 AI 网关（app:3000/api/ai/v1）
```

| 组件 | 说明 |
| --- | --- |
| 镜像 | `ghcr.io/<owner>/opencode-pocket-sandbox:<sha>/latest`，基于官方 `ghcr.io/anomalyco/opencode`，由**本仓库** CI 构建；服务器只 pull。 |
| 边缘 Caddy | 承载全部访客锁定逻辑（见 `infra/vps/sandbox/Caddyfile`）；不发布端口，由博客栈的 Caddy 转发进来。 |
| 配置 | `opencode.json` 烤进镜像只读区，每次启动由 `entrypoint.sh` 覆盖回家目录；访客改配置只影响当次进程，重启即还原。 |
| 网络 | `docker_play`（external，博客栈创建）：只挂 `app`（AI 网关）+ 博客 `caddy`（反代）+ 本栈服务；不接 `web`。 |
| 存储 | `docker_playground-data`（`/workspace`，访客共享）、`docker_playground-home`（会话/状态卷）。均为 external，**不随部署清掉**；要清空需手动删卷。 |

### 与博客栈刻意保留的两处共享（搬不走）

- **网络 `docker_play`**：沙盒要访问博客 AI 网关（`app:3000/api/ai/v1`）；博客 Caddy 要访问
  本栈的 `sandbox-caddy`。
- **卷 `docker_playground-*`**：跨栈复用，里面是访客会话与工作区数据。

> 因此两端都用 `external: true` + 显式 `name:` 引用这两个资源；博客栈的 compose 不再持有
> 沙盒服务，也就不会在 `down -v` 时误删这些卷。

## 访客锁定（`Caddyfile` 要点）

1. **全阶段封禁**（含 GET）：`^/(api/)?(pty|shell|tui)(/|$)` 与 `^/session/[^/]+/(shell|fork)(/|$)`
   → `403`。
2. **`/__shell`**：供自建外壳同步 `fetch` 取回二进制里的真 `index.html`（`rewrite * /` 后反代）。
3. **HTML 文档请求**（`Accept: text/html`）：
   - 路径命中 `/<(global|server/…)/session/<PLAYGROUND_SESSION_ID>/` → 返回自建外壳；
   - 其余 → `302` 跳回固定会话（opencode SPA 会把 URL 客户端改写成
     `/server/<base64(origin)>/session/<id>`，匹配器两种形态都接受）。
4. **其余请求**：只放行该会话下的对话操作（写入白名单），其它一律 `404`/封禁。
5. 会话 id 由 `PLAYGROUND_SESSION_ID` 注入（默认 `ses_guest`）。

自建外壳通过隐藏 `header` / 拦截 `popstate`、`pushState` 等守卫，把访客钉在固定会话内；
手机端右侧 `Session | Changes` 面板**保留**。

## 隔离边界：容器，不是权限配置

`opencode.json` 的 `permission`（bash 安装白名单、`external_directory: deny`）是**软约束**——
opencode 同意后才执行，理论上拦不住绕过。真正的边界是**容器本身**：

- 非 root（uid 10001）、`read_only` 根文件系统、`cap_drop: [ALL]`、`no-new-privileges`、
  `init`、mem/cpu/pids 限额；
- 只挂 `/workspace` 与家目录，宿主其它路径在容器视角**不存在**；
- 只连 `docker_play` 内网，对外唯一可达的是博客 AI 网关（令牌鉴权）；
- 访客之间**共享同一进程与目录**（无「每访客一容器」隔离，互相可见）。

## 权限策略（见 `infra/vps/sandbox/opencode.json`）

- **bash 默认全禁**；白名单只放行「装在当前目录」的安装命令
  （`npm install/i/ci *`、`pnpm install/add *`、`pip/pip3 install *`），并叠加拦截
  元字符与全局安装（`-g`）。⚠️ 拦不住安装脚本 postinstall 执行任意代码——靠容器兜底。
- `external_directory: deny`：不许读写工作区之外的路径（软约束）。
- webfetch / websearch 全放行（沙盒需要联网检索）。
- 模型固定指向博客 AI 网关，由 admin「AI 密钥」页签发的令牌决定实际模型与每日预算。

## 构建与部署

**构建（CI）**：`.github/workflows/sandbox.yml` 只在本仓库 push `main` 且改动落在
`infra/vps/sandbox/**` 时触发，推送 `ghcr.io/<owner>/opencode-pocket-sandbox:<sha>` 与 `:latest`；
镜像公开，服务器匿名 pull，无需在服务器存凭据。

**部署（服务器 cron 轮询）**：GitHub runner 连云安全组的 22 端口常被丢弃，CI 直接 SSH
会超时，因此改为服务器主动轮询：

```cron
*/3 * * * * cd /home/ubuntu/Opencode-Pocket/sandbox && ./auto-deploy.sh >> ./auto-deploy.log 2>&1
```

- `auto-deploy.sh` 解析本仓库 `main` 的最新 SHA → 若 GHCR 已有该 SHA 的镜像且与
  `.last-deployed` 不同，则调用 `ci-run.sh` 部署，成功后写入 `.last-deployed`。
- `ci-run.sh` 会先从公开仓库**稀疏拉取服务器侧配置**（`Caddyfile` / `docker-compose.yml` /
  `deploy.sh` / `ci-run.sh`）—— 服务器这台机器从不 `git pull`，所以配置靠这一步同步。
- 镜像 tag 用该 SHA；`deploy.sh` 拉镜像、无损 `caddy reload` 边缘 Caddy、`up -d`、回收旧镜像。
- 手动部署：`cd ~/Opencode-Pocket/sandbox && ./deploy.sh <sha|latest>`。

### 服务器首次引导（一次性）

```bash
mkdir -p ~/Opencode-Pocket/sandbox
cp infra/vps/sandbox/{auto-deploy.sh,ci-run.sh,deploy.sh} ~/Opencode-Pocket/sandbox/   # 或首次 ./ci-run.sh latest 自动拉全
cp infra/vps/sandbox/.env.example ~/Opencode-Pocket/sandbox/.env   # 填 PLAYGROUND_AI_TOKEN / PLAYGROUND_SESSION_ID
crontab -e   # 追加上面那条 */3
```

博客侧只需在 `docker/Caddyfile` 保留 stub（`code-sandbox` 段 3 行转发到 `sandbox-caddy:80`），
并在博客 compose 里让 `app` / `caddy` 与沙盒同处 `docker_play` 网络。

## 运维要点

- **清空沙盒**：`docker compose -f ~/Opencode-Pocket/sandbox/docker-compose.yml rm -sf opencode-play`
  后删掉 `docker_playground-data` / `docker_playground-home` 卷（注意别在博客栈 `down -v` 时连带删除）。
- **改权限 / 模型**：改 `infra/vps/sandbox/opencode.json`，push 后等 CI 构建 + cron 部署（配置烤进镜像）。
- **改锁定逻辑**：改 `infra/vps/sandbox/Caddyfile`，push 后 cron 部署（`deploy.sh` 会无损 reload）。
- **看消耗**：博客 admin「AI 密钥」页看该令牌用量/上限；429 即当日预算耗尽。
- **私有 pocket 不可从沙盒访问**：两套容器 / 网络完全分开。

## 已知取舍

- 匿名 + 共用会话：可能被当免费推理 / 安装资源，靠网关每日上限 + 容器资源限额控制。
- 访客共享目录：互相可见文件（可留纸条、可互删），刻意的「公共白板」模式。
- 官方镜像较大，首次 pull 稍慢。
