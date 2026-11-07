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

## 静音过滤（`src/filters.js`）

cockpit 建的会话标题一律是 `[节点] 标题`，据此过滤，避免自己的回话刷屏：

| 环境变量 | 默认 | 作用 |
|---|---|---|
| `NOTIFY_MUTE_PREFIXES` | `[ceo]` | 命中前缀的会话**整条不推**（CEO 的邮件/复盘/对话） |
| `NOTIFY_QUIET_PREFIXES` | `[` | 命中前缀只静音 `NOTIFY_QUIET_KINDS` 里的类型 |
| `NOTIFY_QUIET_KINDS` | `done,running` | 「开始运行 / 会话完成」 |

`-` 表示显式关闭该项（例如 `NOTIFY_QUIET_PREFIXES=-`）。
审批 / 提问 / 出错 / 打断不受 quiet 规则影响；人自己开的会话（标题无 `[节点]` 前缀）全部照常推送。

```bash
npm test   # 9 条过滤规则用例
```

## HTTP 端点（本地）

- `GET /health` → `{ ok: true, ... }`
- `POST /register` `{ token, platform }` → 登记设备 token（为 APNs 预备）
- `GET /tokens` → 已登记 token（掩码）
