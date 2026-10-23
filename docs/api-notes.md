# opencode v2 HTTP API 备注（实测 v2.0.26）

Base URL 示例：`http://127.0.0.1:4096`
认证：HTTP Basic，用户名默认 `opencode`，密码 = `OPENCODE_SERVER_PASSWORD`。

大多数响应形如 `{ "data": ... }`（有的带 `location`）。
SSE 流为 `data: {json}\n\n`，并有 `: heartbeat` 注释行。

## 关键端点

| 用途 | 方法 + 路径 |
|---|---|
| 服务信息 | `GET /api/info` |
| 健康 | `GET /api/health` |
| 当前 location | `GET /api/location` |
| session 列表 | `GET /api/session` |
| 活动(running) session | `GET /api/session/active` |
| session 消息历史 | `GET /api/session/{sessionID}/message` |
| 单条消息 | `GET /api/session/{sessionID}/message/{messageID}` |
| 全局事件流(SSE) | `GET /api/event` |
| 单会话事件流(SSE) | `GET /api/session/{sessionID}/event` |
| 下指令 | `POST /api/session/{sessionID}/prompt` |
| 打断 | `POST /api/session/{sessionID}/interrupt` |
| 待办审批列表 | `GET /api/permission` |
| 待答问题列表 | `GET /api/question` |
| 审批回复 | `POST /api/session/{sessionID}/permission/{requestID}/reply` body `{reply: "once"\|"always"\|"reject", message?}` |
| question 回答 | `POST /api/session/{sessionID}/question/{requestID}/reply` body `{answers: string[][]}` |
| question 拒绝 | `POST /api/session/{sessionID}/question/{requestID}/reject` |
| 切模型 | `POST /api/session/{sessionID}/model` |
| 切 agent/mode | `POST /api/session/{sessionID}/agent` |
| agent 列表 | `GET /api/agent` |
| 命令列表 | `GET /api/command` |
| provider/模型 | `GET /api/provider` |
| 回滚 | `POST /api/session/{sessionID}/revert/{stage\|commit\|clear}` |

（另有 v1 兼容路径：`/session/{id}/abort`、`/session/{id}/diff`、`/session/{id}/todo`、`/session/{id}/fork` 等。）

## `/api/session` 元素字段（实测）

```json
{
  "id": "ses_...",
  "projectID": "a4bf...",
  "agent": "build",
  "model": { "id": "deepseek-v4.1-flash", "providerID": "opencode-go", "variant": "default" },
  "cost": 4.72,
  "tokens": { "input": 15631814, "output": 640757, "reasoning": 654412,
              "cache": { "read": 662009856, "write": 0 } },
  "outcome": "succeeded",
  "time": { "created": 1789973696031, "updated": 1791713713451, "idle": ..., "viewed": ... },
  "title": "AI工作状态灯(APP)",
  "location": { "directory": "/Users/liuzixiang/Projects/AI-Status-Light-App" }
}
```

`/api/session/active` 返回：`{"data": { "<sessionID>": {"type":"running"}, ... }}`

## 事件流样例（`GET /api/event`）

```
data: {"id":"evt_...","type":"server.connected","data":{}}

: heartbeat

data: {"id":"evt_...","created":1791713944831,"type":"session.reasoning.delta",
       "location":{"directory":"/Users/liuzixiang/Projects/..."},
       "data":{"sessionID":"ses_...","assistantMessageID":"msg_...","ordinal":0,"delta":"..."}}
```

关注的类型（用于推送）：

- `permission.asked` / `permission.replied`（也可能以 `permission.updated` 出现）
- `question.asked` / `question.replied` / `question.rejected`
- `session.created` / `session.updated` / `session.deleted`
- `session.idle` / `session.error`
- `message.updated` / `message.part.updated`（经典消息流）

## 消息分页规则（实测）

`GET /api/session/{sessionID}/message` 的 `cursor` 与 `order` **互斥**：同时传会返回
`400 InvalidCursorError`。第一页传 `?limit=50&order=desc`，之后翻**更早**的页只传
`?limit=25&cursor=<cursor.next>`（不要带 `order`）。注意：`cursor.previous` 指向更新的一侧，
拿它翻历史会得到空页（v2.0.26 实测）。

消息里的 `content[].state.input/output` 可能极大（一次 shell 输出几百 KB，50 条能到
6MB+），手机端轮询会超时并被系统取消（`NSURLError -999`）。因此 App 走
`pocketd` 的 `GET /pocketd/messages?session=...&limit=...&order=...`（或 `cursor=...`）
中继：只保留 `id/type/agent/model/time/text/finish/error` 和
`content[].{type,text,name,state.status}`，一页通常从 MB 级降到几十 KB。

## 服务发现

`~/.local/state/opencode/service.json`:

```json
{ "id": "...", "version": "2.0.26", "url": "http://127.0.0.1:49374", "pid": 74882, "password": "..." }
```

> 共享后台服务端口是**随机**的。本项目采用**固定端口专用 server**（`--port 4096`），以获得稳定的隧道/App 地址。
