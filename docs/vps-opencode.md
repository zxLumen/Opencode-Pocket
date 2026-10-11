# 已切换到 VPS（opencode 跑在服务器）

> 架构变更：opencode server 从 Mac 移到 VPS，Mac 只当客户端。这样手机/Mac 随时随地可用，
> **不再依赖 Mac 唤醒**。

## 现状

```
VPS(your-vps-host, Ubuntu 24.04):
  ~/.opencode/bin/opencode             v2.0.26
  ~/Projects/*                         代码（从 Mac rsync，排除构建产物；未含 Waveshare）
  systemd: opencode.service            opencode serve --service  (绑定 0.0.0.0:4096, 密码 YOUR_SERVER_PASSWORD)
  systemd: opencode-pocketd.service    pocketd 订阅 /api/event -> 飞书机器人
  Caddy(容器): pocket.example.com -> host.docker.internal:4096
  默认模型: ~/.config/opencode/opencode.jsonc -> "opencode/big-pickle" (OpenCode Zen 免费)

Mac: 已停用 launchd(serve/tunnel/pocketd)。改用 VSCode Remote-SSH 连 VPS。
手机 App: 地址 https://pocket.example.com 不变（现直连 VPS）。
```

## 重要说明

- **授权/模型**：VPS 上没有你 Mac 的第三方 provider 授权（`auth list` 为空），只有内置
  **OpenCode Zen** 免费模型（`opencode/*-free`，如 `opencode/big-pickle`）。默认模型已设为
  `opencode/big-pickle`，新建会话可直接用。若要用 Anthropic/其它，需在 VPS 上 `opencode auth login`。
- **本地 client 接入**：VPS 上 plain `opencode` 会因 advertised url 为 `0.0.0.0` 而连不上，请用：
  ```bash
  opencode --server http://127.0.0.1:4096      # 已在 ~/.bashrc 提供别名 oc
  ```
- **飞书**：pocketd 用「自定义机器人 + 签名校验」推送到飞书群，消息带 `@所有人`。
  仅 VPS IP(your-vps-host) 可发（机器人安全设置为 IP 白名单）。

## 日常用法（Mac）

1. VSCode 装 **Remote - SSH** 扩展 → 连 `ubuntu@your-vps-host` → 打开 `~/Projects/<工程>`。
2. 在 VPS 终端里跑 `oc`（= `opencode --server http://127.0.0.1:4096`）或其他命令。
3. 手机 App 打开即为同一个 server 的会话。

## 运维

```bash
# 服务器
sudo systemctl status opencode opencode-pocketd
sudo systemctl restart opencode            # 改配置后
journalctl -u opencode-pocketd -f          # 看推送日志

# 改密码（同时改 App 侧）
opencode service set password '新密码'
```

## Mac 侧（可选保留）

`infra/mac/*` 的 launchd（serve/tunnel/pocketd）已停用；如需回退到"Mac 本地 server + 隧道"，
`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.opencode.pocket.*` 重新加载即可。
