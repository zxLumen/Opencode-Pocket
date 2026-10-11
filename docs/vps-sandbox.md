# 访客沙盒（公网开放的第二个 opencode 实例）

VPS 上除了私有的 `pocket.{$DOMAIN}`（见 `docs/vps-opencode.md`），还有一套**公开可玩**的
opencode 沙盒：

- 入口子域：`code-sandbox.{$DOMAIN}`（无密码开放，匿名可玩）。
- 容器：`opencode-play`（独立于私有 pocket 的那套）。
- 与私有实例**完全隔离**：各自的容器 / 网络 / 卷互不相通。

> ⚠️ 本仓库只记录**设计边界与 Caddy 片段**；真正的部署实现（Dockerfile、compose 服务、
> 网络、卷、CI 构建）在博客仓库 `zxLumen-Blog` 下维护，避免两处真相漂移：
> - `docker/opencode-play/`（Dockerfile / entrypoint.sh / opencode.json）
> - `docker/docker-compose.yml`（`opencode-play` 服务 + `play` 网络 + 两个卷）
> - `.github/workflows/deploy.yml`（构建推送 `ghcr.io/<owner>/opencode-play`）
> - `docs/PLAYGROUND.md`（博客侧的完整文档）

## 架构

```
访客浏览器
   │ https://code-sandbox.{$DOMAIN}   (Caddy 段，flush_interval -1 放行 SSE)
   ▼
Caddy ── play 内网 ──► opencode-play 容器（opencode web :4096）
                         │ 只接 play 网络，其它子应用一律不可达
                         │
                         ├─ /workspace        ← named volume，访客共享目录（可写）
                         ├─ /home/opencode    ← named volume（会话 / 状态）
                         ├─ /tmp              ← tmpfs
                         └─ ZX_AI_APP_TOKEN → 博客 AI 网关（app:3000/api/ai/v1）
                                                （app 也接 play 网络，仅此一个出口）
```

| 组件 | 说明 |
| --- | --- |
| 镜像 | `ghcr.io/<owner>/opencode-play:<sha>/latest`，基于官方 `ghcr.io/anomalyco/opencode`，由博客仓库 CI 构建；服务器只 pull。 |
| 配置 | `opencode.json` 烤进镜像只读区，每次启动由 `entrypoint.sh` 覆盖回家目录；访客改配置只影响当次进程，重启即还原。 |
| 网络 | 独立 `play` bridge，只挂 `app`（AI 网关）+ `caddy`（反代）；不接 `web`。 |
| 存储 | `playground-data`（`/workspace`，访客共享）、`playground-home`（会话/状态卷）。两者都不在镜像里，**不随部署清掉**；要清空需手动删卷。 |

## 隔离边界：容器，不是权限配置

`opencode.json` 的 `permission`（bash 安装白名单、`external_directory: deny`）是**软约束**——
opencode 同意后才执行，理论上拦不住绕过。真正的边界是**容器本身**：

- 非 root（uid 10001）、`read_only` 根文件系统、`cap_drop: [ALL]`、`no-new-privileges`、
  `init`、mem/cpu/pids 限额；
- 只挂 `/workspace` 与家目录，宿主其它路径在容器视角**不存在**；
- 只连 `play` 内网，对外唯一可达的是博客 AI 网关（令牌鉴权）；
- 访客之间**共享同一进程与目录**（无「每访客一容器」隔离，互相可见）。

结论：沙盒里的一切都出不了容器；能看到的全部世界 = workspace + 家目录 + 网关。

## 权限策略（见博客仓库 `docker/opencode-play/opencode.json`）

- **bash 默认全禁**；白名单只放行「装在当前目录」的安装命令
  （`npm install/i/ci *`、`pnpm install/add *`、`pip/pip3 install *`），并叠加拦截
  元字符与全局安装（`-g`）。⚠️ 拦不住安装脚本 postinstall 执行任意代码——靠容器兜底。
- `external_directory: deny`：不许读写工作区之外的路径（软约束）。
- webfetch / websearch 全放行（沙盒需要联网检索）。
- 模型固定指向博客 AI 网关，由 admin「AI 密钥」页签发的令牌决定实际模型与每日预算。

## Caddy

片段已并入本仓库 `infra/vps/Caddyfile`（与 `pocket.{$DOMAIN}` 段并列）。要点：
`code-sandbox.{$DOMAIN}` → `reverse_proxy opencode-play:4096`，并 `flush_interval -1` 以放行 SSE；
只放 `X-Content-Type-Options` / `Referrer-Policy`，不加 `frame-ancestors`（沙盒是独立顶层页面）。

## 运维要点

- **清空沙盒**：删卷重建（`docker compose rm -sf opencode-play` 后删掉
  `playground-data` / `playground-home` 卷），或只清 `/workspace` 内容。
- **改权限 / 模型**：改博客仓库 `docker/opencode-play/*`，重建镜像生效（配置烤进镜像）。
- **看消耗**：admin「AI 密钥」页看该令牌用量/上限；429 即当日预算耗尽。
- **私有 pocket 不可从沙盒访问**：两套容器 / 网络完全分开。

## 已知取舍

- 匿名 + 无限会话：可能被当免费推理 / 安装资源，靠网关每日上限 + 容器资源限额控制。
- 访客共享目录：互相可见文件（可留纸条、可互删），刻意的「公共白板」模式。
- 官方镜像较大，首次 pull 稍慢。
