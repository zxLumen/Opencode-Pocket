# 访客沙盒（公网开放的 opencode 实例）

VPS 上除了私有的 `pocket.{$DOMAIN}`（见 `docs/vps-opencode.md`），还有一套**公开可玩**的
opencode 沙盒：

- 入口子域：`code-sandbox.{$DOMAIN}`（无密码开放，匿名可玩）。
- 访客进站即落入**工作台**：左=会话、右=通过会话做的网站**实时预览**（固定分栏可拖，
  手机端自动上下分栏）；会话本身仍**锁定**为唯一固定会话：隐藏主页/导航，不能选或新建
  会话、不能改设置、不能加项目、不能离开；只保留手机端右侧 `Session | Changes` 面板。
- **模型全程对访客不可见**：会话里不能查看/管理/调整模型（读接口净化成「仅网关默认」、
  写接口 403、前端隐藏 Select model 按钮）；输入工具条旁新增 **Plan / Build** 切换
  （自制按钮，默认 Plan，访客可自由切换 agent 模式，模型始终固定网关）。
- 与本仓库的私有 pocket、以及博客主站，各自容器 / 网络 / 卷互不相通（仅两处刻意共享，见下）。

> 2026-10 起，沙盒的实现（源码 / CI / 部署 / 配置）**整体在本仓库**，与博客仓库
> `zxLumen-Blog` 解耦；博客侧只剩「TLS + 3 行转发」的 stub。本文件是唯一真相来源，
> 博客侧的 `docs/PLAYGROUND.md` 只是指向这里的指针。

## 目录（本仓库）

```
infra/vps/sandbox/
├── Dockerfile          # 沙盒镜像（基于 ghcr.io/anomalyco/opencode）
│                       #   额外 apk 装了 nodejs:辅助服务(工作台/预览/净化)需要 JS 运行时
├── entrypoint.sh       # 每次启动把只读基准配置烤回家目录 + 后台拉起辅助服务
├── opencode.json       # 基准配置（烤进镜像只读区，运行时改动重启即还原）
├── static-server.mjs   # 容器内辅助服务(:4173):工作台页 / /config净化 / /workspace只读预览
├── hub.html            # 工作台页(固定分栏 + 1s 实时预览 + 手机端上下分栏)
├── seed/               # 播种到工作区/家目录的助手说明与 README（仅缺失时写）
│   ├── AGENTS.md
│   └── README.md
├── Caddyfile           # 边缘 Caddy：code-sandbox 的全部「访客锁定 + 工作台 + 模型封锁」逻辑
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
   │ https://code-sandbox.{$DOMAIN} → GET / → 工作台
   ▼
博客栈 Caddy（占 80/443，只做 TLS + 3 行转发）
   │ reverse_proxy sandbox-caddy:80 { flush_interval -1 }
   ▼
本次部署的 sandbox-caddy（边缘 Caddy，站点 :80）
   │ ① 工作台:GET / → 转发沙盒内辅助服务 :4173 的 /__hub(固定分栏双 iframe)
   │ ② 会话预览:/preview/* → :4173 只读静态(根=/workspace,不列目录)
   │ ③ 锁定:文档请求只认唯一会话、其余 302 回工作台;写入白名单只放行该会话下的
   │    对话操作;pty/shell/tui、session/fork、改模型接口全封
   │ ④ 模型封锁:/provider 净化成「仅网关默认」(剥 apiKey、保留 default 映射);
   │    /api/model 回空壳;GET /config、/global/config → :4173 的净化代理
   │    (去掉含密钥的 provider 块);额外放行 POST /api/session/<id>/agent 供 Plan/Build 切换
   │ ⑤ 其余 HTML 请求返回「自建外壳」(取二进制真 index.html,注入隐藏+守卫)
   ▼
docker_play 内网 ──► opencode-play 容器（opencode web :4096，同容器内辅助服务 :4173）
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

## 路由要点（`Caddyfile`）

1. **全阶段封禁**（含 GET）：`^/(api/)?(pty|shell|tui)(/|$)`、`^/session/[^/]+/(shell|fork)(/|$)`
   与 `^/(api/)?session/[^/]+/model$`（改模型接口）→ `403`。
2. **网站预览通道**：`/preview/*`（仅 GET/HEAD）→ 辅助服务 `:4173` 只读静态
   （根 = `/workspace`，无目录列表、无目录穿越）；其它方法 `403`。
3. **模型「查看」面净化**：`/(api/)?provider…` 回「仅博客 AI 网关」净化壳 —— `all` 只留
   `zxgw`（`options.apiKey` 剥掉、只留 `baseURL`），**`default` 映射保留**
   `{"zxgw":"gateway-default"}`（前端「默认模型」引用非空，发消息才不被 SPA 拦截）；
   `/api/model` 回 `{"location":{},"data":[]}`，`/config/providers` 回 `{"providers":[]}`；
   服务端没有 `/api/model/default` 端点（会落 SPA index.html），另补一条合法响应
   `{"location":{},"data":{"providerID":"zxgw","id":"gateway-default"}}`。
4. **`GET /config`、`/global/config` → 净化代理**（`/__config`、`/__gconfig`）:辅助服务取
   上游真实配置后**删掉 `provider` 块**再返回（网关密钥、内网地址不外泄）；直接 403 会让
   前端 bootstrap 报错，故用净化替代。
5. **`/__shell`**：供自建外壳同步 `fetch` 取回二进制里的真 `index.html`（`rewrite * /` 后反代）。
6. **HTML 文档请求**（`Accept: text/html`）：
   - `GET /`（或 `/hub`）→ 辅助服务 `/__hub` 工作台页；
   - 路径命中 `(global|server/<b64>)/session/<PLAYGROUND_SESSION_ID>/` → 返回自建外壳
     （opencode SPA 会把 URL 客户端改写成 `/server/<base64(origin)>/session/<id>`，匹配器
     两种形态都接受）；
   - 其余 → `302` 回工作台 `/`。
7. **写入白名单**：只放行 `^/session/<id>/` 下的对话操作，以及
   `POST /api/session/<id>/agent`（Plan/Build 切换）；其它一律 `403`。
8. 会话 id 由 `PLAYGROUND_SESSION_ID` 注入（默认 `ses_guest`）。
9. **静态资源长缓存**：`GET /assets/*.{js,css,woff2,图片}` —— bundle 文件名带内容哈希
   （如 `index-BkjnPp3h.js`），可安全 `Cache-Control: public, max-age=31536000, immutable`
   一年；否则访客每次进入都要重下约 2.7MB 的 SPA bundle（进入慢的主因之一）。

自建外壳通过隐藏 `header` / 拦截 `popstate`、`pushState` 等守卫，把访客钉在固定会话内；
手机端右侧 `Session | Changes` 面板**保留**。

外壳注入脚本的性能约定（避免拖慢 SPA 消息渲染）：

- **隐藏用 CSS 兜底 + JS 增量**：隐藏规则由注入 `<style>` 先兜底（`!important`），JS 只在
  初始与新增 DOM 子树上补防内联覆盖，且经 `requestAnimationFrame` 节流合并 —— 不在每次
  React mutation 时全量重扫整棵 DOM（否则消息流渲染会产生上百毫秒长任务，表现为「会话
  出来慢 / 打字卡」）；JS 选择器刻意不含昂贵的 `button:has()`（该规则只留在 CSS 侧）。
- **宽会话栏铺满**：SPA 聊天区默认 `max-width: 800px(2xl 1000px)` 居中，宽屏/把分栏拖宽后
  两侧留大片空白；外壳注入 CSS 覆盖 `[class*="md:max-w-200"]` 等为 `max-width: none`，
  让消息列与输入框铺满整个会话栏。

## 访客工作台（`hub.html` + `static-server.mjs`）

- 入口 `GET /` 不再是固定会话页，而是**工作台**：左=会话 iframe（锁定外壳内），
  右=网站预览 iframe（`/preview/`），**固定分栏**、中间分隔条可拖（比例存
  localStorage），手机端（<820px）自动改为上下分栏（也可拖）。
- 预览**实时性 1 秒级**：工作台每 1 秒 `HEAD /preview/` 探 `Last-Modified` / 长度，
  文件变了才 `reload`（不闪、不丢滚动/画布状态）；另有手动刷新按钮。
- 预览由容器内辅助服务直接读 `/workspace`（`read_only` 语义:只 GET/HEAD、不列目录、
  防穿越）；目录没有 `index.html` 时给中文提示。
- `/workspace` 本身不暴露任何管理接口 —— 访客要往里面放文件，走会话里的 opencode
  （写文件工具）而非 HTTP。

## 模型封锁（访客不可见 / 不可改）

- **读**：`/provider*` 净化成「仅博客 AI 网关」—— `all` 只留 `zxgw` 与其唯一默认模型，
  `options.apiKey`、内网地址之外的信息剥掉；**`default` 映射保留**（SPA 的默认模型引用
  非空，发送消息不再被前端「Select an agent and model」拦截）；`/api/model`、
  `/config/providers` 回空壳；`/config` 净化掉 `provider` 块。
- **写**：`POST/(api/)session/<id>/model` → 403（与 pty/shell/tui 同级封禁）。
- **Plan / Build 切换**：会话外壳在输入工具条注入「Plan | Build」自制按钮 —— 点击发
  `POST /api/session/<id>/agent`（`@write` 白名单里唯一额外放行的写接口），当前模式
  高亮；选择存 `localStorage`（键 `zx-sandbox-agent`，默认 **Plan**）；进入会话时**按需
  同步**（先 `GET /api/session/<id>` 读服务端 agent，与本地期望不一致才 POST，避免每次
  进入都产生无谓的 `agent-switched` 事件）；React 重渲染后由 MutationObserver 自动重建按钮。
- **历史消息**：会话外壳注入 CSS 隐藏 `[data-slot=user-message-meta]` 与
  `[data-slot=text-part-meta]`（模型名与时长同在一个文本节点，整行隐藏最稳）。
- **键盘捷径**：拦截 `Ctrl/Cmd + k / n / , / p`（防止唤起模型选择等浮动面板）。
- 服务端仍按 `opencode.json` 固定的 `zxgw/gateway-default` 走博客 AI 网关，不受影响；
  Plan/Build 只切换 agent 模式，模型始终固定。

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
  模型对访客的「封锁」（净空接口 / 封改模型 / 隐藏控件）在 `Caddyfile` + `static-server.mjs`。
- **改锁定逻辑**：改 `infra/vps/sandbox/Caddyfile`，push 后 cron 部署（`deploy.sh` 会无损 reload）。
- **改工作台 / 预览 / 净化**：改 `infra/vps/sandbox/hub.html` / `static-server.mjs`（两者烤进镜像，
  需重建镜像经 cron 部署）。
- **看消耗**：博客 admin「AI 密钥」页看该令牌用量/上限；429 即当日预算耗尽。
- **私有 pocket 不可从沙盒访问**：两套容器 / 网络完全分开。

## 已知取舍

- 匿名 + 共用会话：可能被当免费推理 / 安装资源，靠网关每日上限 + 容器资源限额控制。
- 访客共享目录：互相可见文件（可留纸条、可互删），刻意的「公共白板」模式。
- 官方镜像较大，首次 pull 稍慢。
