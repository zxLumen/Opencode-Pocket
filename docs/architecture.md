# 架构

## 组件

1. **opencode 共享后台服务（Mac，已固定端口）**
   - opencode v2 默认为当前用户启动**一个**共享后台服务，所有客户端（`opencode` TUI）自动接入 → 多工程天然汇聚。
   - 已通过 `opencode service set hostname 127.0.0.1` + `opencode service set port 4096` 把它**固定到 `127.0.0.1:4096`**。
   - 因此你**直接敲 `opencode` 照常工作**，且全部 session 都在 4096。
   - 配置持久化在 `~/.config/opencode/service.json`（`{hostname, port, password}`）。

2. **反向隧道（Mac → VPS，出站）**
   - Mac 主动 `ssh -R 4096:127.0.0.1:4096 ubuntu@your-vps-host`，把本机 4096 暴露到 VPS 的 127.0.0.1:4096。
   - 不需要端口映射、不需要备案；VPS 端只监听 localhost。

3. **Caddy（VPS）**
   - `pocket.example.com` 自动签发 Let's Encrypt 证书，反代到 `127.0.0.1:4096`。
   - SSE 需 `flush_interval -1`。
   - 不做额外 basic_auth（opencode 自身已用 HTTP Basic，避免双 Authorization 冲突）。

4. **pocketd（Mac，Node）**
   - 订阅 `GET /api/event`，按规则触发通知。
   - 密码/地址自动从 `~/.local/state/opencode/service.json`（运行中服务）与 `~/.config/opencode/service.json` 读取。
   - 通知渠道：`ntfy`（当前）；`apns`（预留，需要付费 Apple 开发者账号）。

5. **iOS App（SwiftUI）**
   - 连接 `https://pocket.example.com`，Basic Auth（用户名 `opencode`）。
   - 会话列表（含 running 状态）→ 会话详情（实时事件流 + 历史消息）→ 审批/提问/指令/切模型。

## 数据流

```
VSCode: opencode ──▶ 共享服务 (Mac:4096)  ◀── 你直接敲 opencode 也走这里
                         │ /api/event (SSE)
                         ├─▶ iOS App (经隧道直连, 实时)
                         └─▶ pocketd ─▶ ntfy ─▶ iPhone (后台提醒)
```

## 认证与安全

- 传输：Caddy 自动 TLS（HTTPS）。
- 认证：opencode HTTP Basic（用户名 `opencode`，密码见 `~/.config/opencode/service.json`），App 存 Keychain。
- 隧道：VPS 监听 localhost，公网仅 443。
- 可选加固：Caddy IP 白名单、fail2ban、限制 SSH 来源。

## 推送

| 方案 | 免费 | 后台/杀进程 | 进自己 App |
|---|---|---|---|
| ntfy（官方中转） | ✓ | ✓ | ✗（落在 ntfy App，可用 click deep-link 跳回） |
| APNs + pocketd | ✗（需 $99/年） | ✓ | ✓ |

当前先用 ntfy 过渡；pocketd 的渠道层已抽象，后续替换为 APNs 不影响其它逻辑。
