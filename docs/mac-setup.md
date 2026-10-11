# Mac 侧部署

## 前置

- opencode v2（`opencode --version` 应输出 `2.0.x`）
- Node 20+（用于 pocketd）
- 已配置到 VPS 的 SSH 免密登录（`ssh ubuntu@your-vps-host` 可直接登录）

## 1. 生成配置

```bash
cd ~/Projects/Opencode-Pocket
./infra/mac/install-mac.sh
```

脚本会：

1. 创建 `~/.config/opencode-pocket/env`（含随机强密码、ntfy 配置、VPS 地址），若已存在则保留。
2. 创建 `~/.local/state/opencode-pocket/` 日志目录。
3. 把 launchd plist 从仓库模板渲染到 `~/Library/LaunchAgents/`。
4. 加载 `serve` / `tunnel` / `pocketd` 三个服务。

编辑 `~/.config/opencode-pocket/env` 填入 `VPS_HOST` / `VPS_USER` / ntfy 配置。

## 2. 手动启动/停止

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.opencode.pocket.serve.plist
launchctl bootout   gui/$(id -u)/ai.opencode.pocket.serve
# 查看
launchctl list | grep opencode.pocket
```

## 3. 让 VSCode 的 TUI 接入固定 server

不要再用旧扩展的 `opencode --port <随机>`。改为在工程里跑：

```bash
opencode --server http://127.0.0.1:4096
```

或在 VSCode 里用一个 Task / 终端命令。也可安装 `oc` 包装脚本：

```bash
source ~/Projects/Opencode-Pocket/infra/mac/oc.sh   # 提供 oc 命令
oc            # 等价于 opencode --server http://127.0.0.1:4096
```

## 4. 验证

```bash
# 本机直连
curl -u opencode:$OPENCODE_SERVER_PASSWORD http://127.0.0.1:4096/api/info

# 经隧道 + Caddy（公网）
curl -u opencode:$OPENCODE_SERVER_PASSWORD https://pocket.example.com/api/info

# 活动 session
curl -u opencode:$OPENCODE_SERVER_PASSWORD http://127.0.0.1:4096/api/session/active
```

## 5. 清理旧的随机端口 server（可选）

```bash
# 找到并结束遗留进程
lsof -nP -iTCP -sTCP:LISTEN | grep opencode
# kill <pid>
```

> 注意：不要启用 `opencode service disabled`（会让 plain `opencode` 各自起私有 server）。
