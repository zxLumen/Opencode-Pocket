# 架构

## 组件

1. **opencode server（Mac，固定端口）**
   - `opencode serve --hostname 127.0.0.1 --port 4096`，密码经 `OPENCODE_SERVER_PASSWORD` 注入。
   - 由 launchd 常驻（KeepAlive）。
   - 所有 VSCode 窗口的 TUI 通过 `opencode --server http://127.0.0.1:4096` 接入 → 全部 session 汇聚到一个 server。

2. **反向隧道（Mac → VPS，出站）**
   - Mac 主动 `ssh -R 4096:127.0.0.1:4096 ubuntu@your-vps-host`，把本机 4096 暴露到 VPS 的 127.0.0.1:4096。
   - 不需要端口映射、不需要备案；VPS 端只监听 localhost。

3. **Caddy（VPS）**
   - `pocket.example.com` 自动签发 Let's Encrypt 证书，反代到 `127.0.0.1:4096`。
   - SSE 需 `flush_interval -1`。
   - 不做额外 basic_auth（opencode 自身已用 HTTP Basic，避免双 Authorization 冲突）。

4. **pocketd（Mac，Node）**
   - 订阅 `GET /api/event`，按规则触发通知。
   - 通知渠道：`ntfy`（当前）；`apns`（预留，需要付费 Apple 开发者账号）。
   - 另起一个小 HTTP 端口用于设备注册/健康检查。

5. **iOS App（SwiftUI）**
   - 连接 `https://pocket.example.com`，Basic Auth。
   - 会话列表（含 running 状态）→ 会话详情（实时事件流 + 历史消息）→ 审批/提问/指令/切模型。

## 数据流

```
VSCode TUI ──(--server)──▶ opencode server (Mac:4096)
                                   │ /api/event (SSE)
                                   ├─▶ iOS App (经隧道直连, 实时)
                                   └─▶ pocketd ─▶ ntfy ─▶ iPhone (后台提醒)
```

## 为什么不用默认共享后台服务

v2 默认的共享后台服务端口**随机**（如 49374），且随重启变化，不利于隧道与 App 固定地址。
因此使用**固定端口专用 server**（B 方案），并用 `--server` 让所有 TUI 明确接入。

## 安全

- 传输：Caddy 自动 TLS（HTTPS）。
- 认证：opencode HTTP Basic（强随机密码），App 存 Keychain。
- 隧道：VPS 监听 localhost，公网仅 443。
- 可选加固：Caddy `@allow` IP 白名单、fail2ban、限制 SSH 来源。

## 推送

| 方案 | 免费 | 后台/杀进程 | 进自己 App |
|---|---|---|---|
| ntfy（自建/官方中转） | ✓ | ✓ | ✗（落在 ntfy App，可用 click deep-link 跳回） |
| APNs + pocketd | ✗（需 $99/年） | ✓ | ✓ |

当前先用 ntfy 过渡；pocketd 的渠道层已抽象，后续替换为 APNs 不影响其它逻辑。
