# 访客沙盒（公网开放的 opencode 实例）

VPS 上除了私有的 `pocket.{$DOMAIN}`（见 `docs/vps-opencode.md`），还有一套**公开可玩**的
opencode 沙盒：

- 入口子域：`code-sandbox.{$DOMAIN}`（无密码开放，匿名可玩）。
- 访客进站即落入**工作台**：左=会话、右=通过会话做的网站**实时预览**（固定分栏可拖，
  手机端自动上下分栏）；会话本身仍**锁定**为唯一固定会话：隐藏主页/导航，不能选或新建
  会话、不能改设置、不能加项目、不能离开。
- **模型全程对访客不可见**：会话里不能查看/管理/调整模型（读接口净化成「仅网关默认」、
  改模型写接口被强制成网关默认、前端隐藏模型入口）；输入工具条旁新增 **Plan / Build** 切换
  （自制按钮，默认 Plan，访客可自由切换 agent 模式，模型始终固定网关）。
- 与本仓库的私有 pocket、以及博客主站，各自容器 / 网络 / 卷互不相通（仅两处刻意共享，见下）。

> 2026-10 起，沙盒的实现（源码 / CI / 部署 / 配置）**整体在本仓库**，与博客仓库
> `zxLumen-Blog` 解耦；博客侧只剩「TLS + 3 行转发」的 stub。本文件是唯一真相来源，
> 博客侧的 `docs/PLAYGROUND.md` 只是指向这里的指针。

## 版本（重要）

- 运行镜像：`ghcr.io/anomalyco/opencode:**2.0.27**`。
- Web UI：**从 opencode 源码 v2.0.27 裁剪**（见 `app-fork/` + `build-app.sh`），与运行镜像
  **同版本**——否则路由 / 接口 / 鉴权对不上（v1.19 与 v2.0 是两条并行发布线，差异很大）。

### v2.0.x 与 v1.19 的关键差异（迁移要点）

| 维度 | v1.19（旧） | v2.0.27（当前） |
| --- | --- | --- |
| 会话路由 | `/:dir/session/:id`（含 `/global/session/x`） | `/server/<base64(origin)>/session/<id>` |
| UI 资源前缀 | `/assets/*`、图标 `/favicon-*` | `/_assets/*`、图标 `/icons/prod/*` |
| API 路径 | `/session/...`、`/provider`、`/config` | **全部在 `/api/*` 下**（`/api/session`、`/api/provider`、`/api/model`、`/api/config`…） |
| 鉴权 | 无 | 绑 `0.0.0.0` 时**强制 Basic 鉴权** |
| UI 架构 | `pages/`+`components/` | `shell/`+`routes/`（本仓库已按此裁剪） |

## 目录（本仓库）

```
infra/vps/sandbox/
├── Dockerfile          # 多阶段:构建裁剪版 UI → 装进 opencode:2.0.27 运行镜像
├── build-app.sh        # 拉 opencode@v2.0.27 → 打 patch → 构建 packages/app → dist(并分离 sourcemap)
├── app-fork/
│   └── app-fork.patch  # 我们对 packages/app 的裁剪(去标题栏/标签/设置/新建会话)
├── entrypoint.sh       # 每次启动把只读基准配置烤回家目录 + 现算上游 Basic 凭据 + 后台拉起辅助服务
├── opencode.json       # 基准配置（烤进镜像只读区，运行时改动重启即还原）
├── static-server.mjs   # 容器内辅助服务(:47311):提供裁剪版 UI / 净化模型与配置 / 工作台 / 预览
├── hub.html            # 工作台页(固定分栏 + 1s 实时预览 + 手机端上下分栏)
├── seed/               # 播种到工作区/家目录的助手说明与 README（仅缺失时写）
│   ├── AGENTS.md
│   └── README.md
├── Caddyfile           # 边缘 Caddy：全部「访客锁定 + 工作台 + 模型封锁 + 上游鉴权注入」逻辑
├── docker-compose.yml  # 三服务：sandbox-caddy / opencode-play / opencode-play-init
├── deploy.sh           # 部署（拉镜像 → reload 边缘 Caddy → up -d → 回收旧镜像）
├── ci-run.sh           # 部署入口：先同步服务器侧配置，再交给 deploy.sh
├── auto-deploy.sh      # cron 轮询部署（见下）
└── .env.example        # 服务器 .env 模板（不入库）
.github/workflows/sandbox.yml   # CI：构建推送镜像 + 导出 sourcemap artifact
```

## 架构

```
访客浏览器
   │ https://code-sandbox.{$DOMAIN} → GET / → 工作台
   ▼
博客栈 Caddy（占 80/443，只做 TLS + 3 行转发）
   │ reverse_proxy sandbox-caddy:80 { flush_interval -1 }
   ▼
本次部署的 sandbox-caddy（边缘 Caddy，站点 :80）
   │ ① 工作台:GET / → 辅助服务 :47311 的 /__hub(固定分栏双 iframe)
   │ ② 预览:/preview/* → :47311:静态文件优先,其余反代到访客后端(约定端口 8000)
   │ ③ UI/静态:/_assets、/assets、/icons、根级文件 → :47311(裁剪版 dist)
   │ ④ 锁定:文档请求只认唯一会话、其余 302 回工作台;写入白名单只放行该会话下的对话操作
   │    危险族(fs/pty/shell 执行/credential/mcp/integration/plugin/debug/experimental/rpc/pair/tui)
   │    与 session 内 shell|fork 全封(403)
   │ ⑤ 模型封锁:/api/provider、/api/model、/api/model/default → :47311 净化(剥 apiKey);
   │    /api/config → :47311 净化(删 providers 块);改模型 POST → :47311 强制网关默认;
   │    额外放行 POST /api/session/<id>/agent 供 Plan/Build 切换
   │ ⑥ 上游鉴权:向上游 opencode 注入 Authorization: Basic <opencode:密码>(对访客透明)
   ▼
docker_play 内网 ──► opencode-play 容器（opencode serve :4096，同容器内辅助服务 :47311）
                           │ 只接 docker_play，其它子应用一律不可达
                           ├─ /workspace        ← named volume，访客共享目录（可写）
                           ├─ /home/opencode    ← named volume（会话 / 状态）
                           ├─ /tmp              ← tmpfs
                           └─ ZX_AI_APP_TOKEN → 博客 AI 网关（app:3000/api/ai/v1）
```

| 组件 | 说明 |
| --- | --- |
| 镜像 | `ghcr.io/<owner>/opencode-pocket-sandbox:<sha>/latest`，基于官方 `ghcr.io/anomalyco/opencode:2.0.27` + 裁剪版 UI，由**本仓库** CI 构建；服务器只 pull。 |
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

## 上游鉴权（v2.0.x 强制 Basic）

opencode v2.0.x 绑 `0.0.0.0` 时**强制 Basic 鉴权**（不设密码则每次启动随机生成、且每次
都不同，导致上游凭据漂移）。做法：

- `PLAYGROUND_SERVER_PASSWORD`（服务器 `.env`）同时注入 `opencode-play`
  （`OPENCODE_SERVER_PASSWORD`）与 `sandbox-caddy`。
- **边缘 Caddy**：现算 `SANDBOX_UPSTREAM_AUTH="Basic base64(opencode:密码)"`，对所有
  转发到 opencode 的请求 `header_up Authorization`（并剥掉客户端自带 Cookie），访客侧
  完全无感、不暴露任何凭据。
- **容器内辅助服务**：`entrypoint.sh` 用同一密码现算 `SANDBOX_UPSTREAM_AUTH`，供
  `static-server.mjs` 直连 `127.0.0.1:4096` 时使用。
- **init 容器**：`curl -u opencode:$PASSWORD` 建会话。

## 路由要点（`Caddyfile`）

1. **危险族全阶段封禁**（读+写，403）：`^/api/(fs|pty|credential|mcp|integration|plugin|debug|experimental|rpc|pair|tui)(/|$)`、
   `^/api/shell/`（shell 执行）、`/api/location/reload`、`/api/config/shell`，
   以及会话内 `^/api/session/[^/]+/(shell|fork)(/|$)`。
2. **预览通道**：`/preview/*`（任意方法）→ 辅助服务 `:47311`——**静态文件优先**，其余
   （不存在的前端资源 / API / 写请求）**反代到访客后端**（约定端口 `8000`）。
   （根 = `/workspace`，无目录列表、无目录穿越）。
3. **模型「查看」面净化**（→ `:47311` 的 `/__provider`、`/__model`、`/__model-default`）：
   `/api/provider` 只留 `zxgw`、`/api/model` 只留 `zxgw` 的模型、`/api/model/default`
   剥掉 `settings`；均**去掉 `settings.apiKey`**（v2.0.x 这些响应里会带网关密钥）。
4. **`GET /api/config` → 净化代理**（`/__config`）：辅助服务取上游真实配置后**删掉每一项的
   `info.providers` / `info.provider` 块**（网关密钥、内网地址不外泄）。
5. **改模型**：`POST /api/session/<id>/model` → `:47311`，辅助服务**忽略请求体**、一律写死
   `{"model":{"id":"gateway-default","providerID":"zxgw"}}` 再转发（即使有人手工构造也换不了）。
6. **HTML 文档请求**（`Accept: text/html`）：
   - `GET /`（或 `/hub`）→ 辅助服务 `/__hub` 工作台页；
   - 路径命中 `^/server/[^/]+/session/<PLAYGROUND_SESSION_ID>/` → 返回裁剪版 UI 外壳
     （辅助服务读 `/srv/app-dist/index.html` 注入外壳代码后一次性返回）；
   - 其余 → `302` 回工作台 `/`。
7. **写入白名单**：只放行 `^/api/session/<id>/` 下的对话操作，以及
   `POST /api/session/<id>/agent`（Plan/Build 切换）；其它一律 `403`。
8. **静态资源长缓存**：`GET /(_assets|assets|icons)/*` 与根级文件 → `:47311`；
   带内容哈希的资源 `Cache-Control: public, max-age=31536000, immutable`。
9. 会话 id 由 `PLAYGROUND_SESSION_ID` 注入（默认 `ses_guest`）。
10. **响应压缩**：站点级 `encode zstd gzip`；opencode 的 SSE 响应带
    `Cache-Control: no-transform`，Caddy 据此**跳过压缩**，事件流保持不缓冲直通。

## 裁剪版 UI（`app-fork/` + `build-app.sh`）

- `build-app.sh`：`git clone opencode@v2.0.27 tag` → `git apply app-fork.patch` →
  `bun install` → `OPENCODE_CHANNEL=prod bun run --cwd packages/app build`。
  - 必须用 **prod channel**：图标/资源前缀才是 `/icons/prod/*`（dev 是 `/icons/dev/*`）。
  - `app-fork.patch` 改动 `packages/app/src/shell/shell.tsx`（去标题栏/竖向标签栏）与
    `packages/app/src/shell/routes/routes.tsx`（去 `/settings`、`/new-session` 路由）。
- **sourcemap（方案 B：不进公开镜像，但留档）**：构建产出的 `.map`（约 59MB）由
  `build-app.sh` 分离到 `/build/app-maps`，**运行镜像不含它们**（只 `COPY dist`）；
  CI 用 `docker buildx build --target app-maps --output type=local` 导出为
  **artifact `app-maps-<sha>`**（保留 90 天）。出事时按同一 sha 取 artifact 还原源码栈。
  同时去掉 JS/CSS 末尾的 `sourceMappingURL` 注释，避免 DevTools 拉取不存在的 map。
- 辅助服务从 `/srv/app-dist` 提供 UI（`/`、`/_assets/*`、`/assets/*`、`/icons/*`、根级文件），
  opencode **只出 API**。

## 外壳注入（`static-server.mjs`）

裁剪版已去掉了标题栏/标签/设置/新建会话；辅助服务在其之上再注入 `SHELL_CSS` + `SHELL_CLIENT`
做「访客锁定」：

- **隐藏残留入口**：`button[data-action="composer-model"]`（模型选择）、
  `button[aria-label="Choose model variant"]`、`More options`、`Toggle review`、
  `Session details`、`View context usage` 等，以及 `[data-slot=user-message-meta]` /
  `[data-slot=text-part-meta]`（历史消息里的模型名与时长）。
- **Plan / Build 切换**：注入「Plan | Build」自制按钮（默认 Plan，存 `localStorage`
  键 `zx-sandbox-agent`）；点击发 `POST /api/session/<id>/agent`；进入会话时按需同步服务端
  agent（不一致才 POST，避免无谓 `agent-switched`）。
- **键盘捷径**：捕获阶段拦 `Ctrl/Cmd + k / n / , / p` 与 `Ctrl/Cmd + Shift + R`。
- **斜杠命令全禁**：输入框为空时按 `/`、或输入以 `/` 开头时回车 → 拦掉。
- **思考摘要默认开启**：启动前合并写 `localStorage['settings.v3']` 的
  `general.showReasoningSummaries = true`。
- **Service Worker**：注册 `/sw.js`（辅助服务提供），只缓存不可变的 `/_assets/*`。

> ⚠️ 斜杠命令**只在客户端拦**：不要在边缘把 `GET /api/command` 置空——会让 SPA 的 command
> bootstrap 抛错并弹「无法重新加载」toast。

## 访客工作台（`hub.html` + `static-server.mjs`）

- 入口 `GET /` 是**工作台**：左=会话 iframe（`/server/<base64(origin)>/session/<id>`），
  右=网站预览 iframe（`/preview/`），**固定分栏**、分隔条可拖（比例存 localStorage），
  手机端（<820px）自动上下分栏。预览 iframe **延迟挂载**（等会话输入框就绪，兜底 6s）。
- 预览**实时性 1 秒级**：每 1 秒 `HEAD /preview/` 探 `Last-Modified` / 长度，变了才 reload。
- **访客后端反代**：`/preview/*` 里不存在的前端资源 / API / 写请求整体反代到容器内
  `127.0.0.1:8000`。前端请用**相对路径** `fetch('api/scores')`（→ `/preview/api/scores`），
  不要用绝对 `/api/*`（会撞 opencode）。约定写进沙盒 `AGENTS.md`。
- **保留端口**：`4096`（opencode）、`47311`（辅助服务）禁止占用/杀进程；访客后端固定 `8000`。
  辅助服务由 `entrypoint.sh` 的**监督循环常驻**，被误杀会自动拉起（否则整站 404）。

## 模型封锁（访客不可见 / 不可改）

- **读**：`/api/provider`、`/api/model`、`/api/model/default`、`/api/config` 全部由辅助服务
  净化：只暴露 `zxgw` 与其默认模型，**剥掉 `settings.apiKey`**（v2.0.x 会带密钥）。
- **写**：`POST /api/session/<id>/model` 由辅助服务**强制成网关默认模型**（忽略请求体）。
- **Plan / Build**：外壳注入的自制按钮切换 agent（唯一额外放行的写接口是
  `POST /api/session/<id>/agent`）。
- 服务端仍按 `opencode.json` 固定的 `zxgw/gateway-default` 走博客 AI 网关。

## 隔离边界：容器，不是权限配置

`opencode.json` 的 `permission`（bash 已放开、`external_directory: deny`）是**软约束**——
真正的边界是**容器本身**：

- 非 root（uid 10001）、`read_only` 根文件系统、`cap_drop: [ALL]`、`no-new-privileges`、
  `init`、mem/cpu/pids 限额；
- 只挂 `/workspace` 与家目录，宿主其它路径在容器视角**不存在**；
- 只连 `docker_play` 内网，对外唯一可达的是博客 AI 网关（令牌鉴权）；
- 访客之间**共享同一进程与目录**（无「每访客一容器」隔离，互相可见）。

## 权限策略（见 `infra/vps/sandbox/opencode.json`）

- **bash 全放开**：访客的 agent 可在容器内跑任意命令（含起后端）。容器隔离是唯一边界。
  **交互式终端仍封**（边缘 `pty/shell/tui` + `/api/session/<id>/(shell|fork)` 403）。
- `external_directory: deny`：不许读写工作区之外的路径（软约束）。
- webfetch / websearch 全放行（沙盒需要联网检索）。
- 模型固定指向博客 AI 网关，由 admin「AI 密钥」页签发的令牌决定实际模型与每日预算。

## 构建与部署

**构建（CI）**：`.github/workflows/sandbox.yml` 只在本仓库 push `main` 且改动落在
`infra/vps/sandbox/**` 时触发，推送 `ghcr.io/<owner>/opencode-pocket-sandbox:<sha>` 与 `:latest`，
并额外导出 sourcemap artifact。镜像公开，服务器匿名 pull，无需在服务器存凭据。

**部署（服务器 cron 轮询）**：GitHub runner 连云安全组的 22 端口常被丢弃，CI 直接 SSH
会超时，因此改为服务器主动轮询：

```cron
*/3 * * * * cd /home/ubuntu/Opencode-Pocket/sandbox && ./auto-deploy.sh >> ./auto-deploy.log 2>&1
```

- `auto-deploy.sh` 解析本仓库 `main` 的最新 SHA → 若 GHCR 已有该 SHA 的镜像且与
  `.last-deployed` 不同，则调用 `ci-run.sh` 部署，成功后写入 `.last-deployed`。
- `ci-run.sh` 会先从公开仓库**稀疏拉取服务器侧配置**（`Caddyfile` / `docker-compose.yml` /
  `deploy.sh` / `ci-run.sh` / `auto-deploy.sh`）—— 服务器这台机器从不 `git pull`。
- 镜像 tag 用该 SHA；`deploy.sh` 拉镜像、无损 `caddy reload` 边缘 Caddy、`up -d`、回收旧镜像。
- 手动部署：`cd ~/Opencode-Pocket/sandbox && ./deploy.sh <sha|latest>`。

### 服务器首次引导（一次性）

```bash
mkdir -p ~/Opencode-Pocket/sandbox
cp infra/vps/sandbox/{auto-deploy.sh,ci-run.sh,deploy.sh} ~/Opencode-Pocket/sandbox/   # 或首次 ./ci-run.sh latest 自动拉全
cp infra/vps/sandbox/.env.example ~/Opencode-Pocket/sandbox/.env
# 填 PLAYGROUND_AI_TOKEN / PLAYGROUND_SESSION_ID / PLAYGROUND_SERVER_PASSWORD(足够随机)
crontab -e   # 追加上面那条 */3
```

博客侧只需在 `docker/Caddyfile` 保留 stub（`code-sandbox` 段 3 行转发到 `sandbox-caddy:80`），
并在博客 compose 里让 `app` / `caddy` 与沙盒同处 `docker_play` 网络。

## 运维要点

- **清空沙盒**：`docker compose -f ~/Opencode-Pocket/sandbox/docker-compose.yml rm -sf opencode-play`
  后删掉 `docker_playground-data` / `docker_playground-home` 卷（注意别在博客栈 `down -v` 时连带删除）。
- **改权限 / 模型 / UI 裁剪**：改 `opencode.json` / `app-fork/app-fork.patch` / `build-app.sh`，
  push 后等 CI 构建 + cron 部署（配置与 dist 烤进镜像）。
- **改锁定逻辑**：改 `Caddyfile`，push 后 cron 部署（`deploy.sh` 会无损 reload）。
- **改工作台 / 预览 / 净化 / 外壳**：改 `hub.html` / `static-server.mjs`（烤进镜像，需重建）。
- **看消耗**：博客 admin「AI 密钥」页看该令牌用量/上限；429 即当日预算耗尽。
- **私有 pocket 不可从沙盒访问**：两套容器 / 网络完全分开。

## 故障排查

- **整站 404**：容器内辅助服务被误杀。entrypoint 有监督循环会自愈；确认日志有
  `[sandbox-helper] listening on :47311`。
- **全站 401**：上游鉴权没对上。检查服务器 `.env` 的 `PLAYGROUND_SERVER_PASSWORD` 是否非空、
  `sandbox-caddy` 与 `opencode-play` 是否都拿到同一值（改后需 `up -d` 重建两个容器）。
- **发消息报错 / 模型不对**：确认 `POST /api/session/<id>/model` 走的是辅助服务（`204`），
  且 `opencode.json` 的 `model` 指向 `zxgw/gateway-default`。
- **UI 白屏 / 资源 404**：确认镜像里 `/srv/app-dist/index.html` 存在，且 Caddy 把
  `/_assets`、`/icons` 路由到 `:47311`。
- **前端接口 403 噪音**：`/api/integration`、`/api/mcp`、`/api/worktree/refresh` 被有意封禁，
  仅产生 console 资源错误，不影响会话。

## 已知取舍

- 匿名 + 共用会话：可能被当免费推理 / 安装资源，靠网关每日上限 + 容器资源限额控制。
- 访客共享目录：互相可见文件（可留纸条、可互删），刻意的「公共白板」模式。
- 运行镜像与 UI 源码必须同版本（当前 v2.0.27）；升级需同时改 `Dockerfile` 基础镜像 tag 与
  `build-app.sh` 的 `OPENCODE_COMMIT`，并重做 `app-fork.patch`。
