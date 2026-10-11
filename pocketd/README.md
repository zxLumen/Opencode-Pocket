# pocketd

常驻守护进程：订阅 opencode 的 `GET /api/event`，命中规则后推送通知。

## 运行

```bash
cd pocketd
cp .env.example .env   # 填 OPENCODE_SERVER_PASSWORD / NTFY_TOPIC
npm start
```

无第三方依赖（Node 20+ 内置 fetch）。

## 通道

- `ntfy`：当前启用（免费、可后台）。通知点击会用 `POCKET_URL_SCHEME` 深链回 App。
- `apns`：预留。需要付费 Apple 开发者账号（推送证书）后实现。

## 规则（`src/rules.js`）

| 事件 | 通知 |
|---|---|
| `permission.*`(ask/updated/request) | 「需要审批」高优先级 |
| `question.*`(ask/request) | 「需要回答」高优先级 |
| `session.error` | 「会话出错」紧急 |
| `session.idle` | 「会话空闲」（默认关闭，`NOTIFY_IDLE=true` 开启）|

## HTTP 端点（本地）

- `GET /health` → `{ ok: true, ... }`
- `POST /register` `{ token, platform }` → 登记设备 token（为 APNs 预备）
- `GET /tokens` → 已登记 token（掩码）
