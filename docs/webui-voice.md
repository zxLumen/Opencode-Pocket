# 私有 WebUI：语音 + 文本输入（pocket.{$DOMAIN}）

手机/桌面上直接打开 `https://pocket.zxlumen.cn`，就是 opencode 的 WebUI。本目录记录
「语音输入 + 中文回车发送」这条补丁的构建与部署方式。

## 改了什么

源码在 opencode 仓库（本地工作副本 `~/Projects/opencode-pocket-wt`，分支
`feat/webui-voice-input`）：

| 文件 | 改动 |
|---|---|
| `packages/app/src/composer/voice.ts` | 新增：MediaRecorder 录音 → `POST /pocketd/asr` → 转写文本 |
| `packages/app/src/composer/editor/editor.tsx` | 输入栏加麦克风按钮；录音/识别状态提示；转写完成后直接发送；中文输入法回车不误发 |
| `packages/app/src/composer/model.ts` | 把当前服务器的 Basic 凭证传给语音请求（复用 opencode 认证） |
| `packages/client/src/solid/connection.ts` | 事件流连接超时 2s → 8s（把线上原 Caddy 热补丁落回源码） |
| `pocketd/src/server.js` | 新增 `POST /asr` 中继：校验 opencode 凭证 → 转发到 voice-chat 的 Qwen3-ASR |

文本输入和语音输入**并存**：麦克风在发送键左侧，点一下开始录音，再点一下结束并发送；
文本输入框保持原样，回车发送、Shift+回车换行。

## 构建（在 opencode 工作副本里）

```bash
cd ~/Projects/opencode-pocket-wt/packages/app
node node_modules/vite/bin/vite.js build
```

## 部署（在 VPS 上）

```bash
# 1) 同步 WebUI 静态资源 + reload Caddy
~/Projects/Opencode-Pocket/infra/vps/deploy-webui.sh

# 2) pocketd 的 /asr 路由（改过 pocketd 时才需要重启）
sudo systemctl restart opencode-pocketd.service
```

Caddy 的 pocket 段见 [`infra/vps/Caddyfile`](./Caddyfile)。线上实际文件在
`/home/ubuntu/zxLumen-Blog/docker/caddy/sites/pocket.caddy`（由 zxLumen-Blog 仓库
部署时同步；直接改线上文件会在下次整站部署时被覆盖）。

## 验收

1. 打开 `https://pocket.zxlumen.cn`，用 `opencode service get password` 的密码连接。
2. 进任意会话，输入中文，按回车 → 消息发出；输入法选词时按回车不会误发。
3. 点输入栏左侧麦克风，说一句话，再点一次 → 显示「正在识别…」→ 自动把转写文本发出。

## 排障

```bash
journalctl -u opencode-pocketd -n 100 --no-pager
curl -s -u opencode:<password> -X POST http://127.0.0.1:8788/asr \
  -H 'content-type: audio/wav' --data-binary @sample.wav
```

- 401：浏览器里的 opencode 凭证过期，重新连接服务器。
- 429：语音识别限流（默认 30 次/5 分钟/IP，1800 秒/天）。
- 502：上游 ASR 不可用，先看 `https://voice.zxlumen.cn/api/health`。
