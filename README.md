# Opencode-Pocket

iOS 优先的移动端控制台：实时跟进本机 opencode 的所有 session，并在手机上完成审批、回答提问、下达指令、切换模型/模式。

## 目标场景

本机（Mac）多个 VSCode 窗口各有一个 opencode TUI。手机上要能：

- 看到**所有** session 的实时执行情况（跨工程目录）
- 处理 permission 审批、agent 提问（question）
- 下达命令 / 打断 / 切模型 / 切 mode

## 架构一览

```
iPhone (SwiftUI App)
   │  https://pocket.example.com  (Basic Auth: opencode:<password>)
   ▼
VPS your-vps-host   ── Caddy (Let's Encrypt TLS, reverse_proxy)
   ▲  ssh -R 反向隧道（Mac 主动外连，出站，无需端口映射/备案）
   │
Mac
   ├─ opencode serve --hostname 127.0.0.1 --port 4096   (launchd 常驻, 固定端口)
   ├─ VSCode 各窗口: opencode --server http://127.0.0.1:4096   (全部汇聚到同一 server)
   └─ pocketd (Node) 订阅 /api/event → ntfy 推送 (未来 APNs)
```

## 目录

| 目录 | 说明 |
|---|---|
| `docs/` | 架构、API 备注、部署指引 |
| `infra/mac/` | Mac 侧 launchd plist、autossh 隧道、安装脚本 |
| `infra/vps/` | VPS 侧 Caddyfile、安装脚本 |
| `infra/vps/sandbox/` | 公开访客沙盒 `code-sandbox.{$DOMAIN}`：镜像 / compose / 边缘 Caddy / 部署脚本（见 `docs/vps-sandbox.md`） |
| `pocketd/` | Mac 常驻守护进程：订阅事件、触发推送 |
| `ios/` | SwiftUI App（XcodeGen 生成工程） |

## 快速开始

见 [`docs/mac-setup.md`](docs/mac-setup.md) 与 [`docs/vps-setup.md`](docs/vps-setup.md)。

### iOS App

```bash
cd ios
xcodegen generate          # 由 project.yml 生成 OpencodePocket.xcodeproj
open OpencodePocket.xcodeproj
```

模拟器可直接运行；真机需在 Xcode 里设置 `DEVELOPMENT_TEAM`。

> **免费侧载（无 Mac、无付费账号）**：见 [`docs/ios-sidestore.md`](docs/ios-sidestore.md)——
> GitHub Actions 自动构建无签名 IPA → 手机 SideStore 用免费 Apple ID 签名安装并自动续签。
> 服务器端配套：`infra/vps/anisette/`（自建 anisette-v3）+ `infra/vps/Caddyfile` 的 `anisette.{$DOMAIN}` 段。

## 关键事实（已实测 opencode v2.0.26）

- opencode v2 默认会为当前用户启动**一个共享后台 server**，所有客户端自动接入 → 多工程天然聚合。
- 认证为 **HTTP Basic**：用户名默认 `opencode`，密码来自 `OPENCODE_SERVER_PASSWORD`。
- 服务发现文件：`~/.local/state/opencode/service.json`（含 `url`/`pid`/`password`）与 `~/.config/opencode/service.json`。
- 旧版 VSCode 扩展执行 `opencode --port <随机>`（v1 语法，v2 顶层无此参数）→ 会导致每窗口独立 server；本项目改用 `--server` 指向固定端口。
