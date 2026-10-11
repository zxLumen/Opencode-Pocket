# Mac 侧部署

## 前置

- opencode v2（`opencode --version` → `2.0.x`）
- Node 20+（pocketd）
- 已配置到 VPS 的 SSH 免密登录（`ssh ubuntu@your-vps-host`）

## 0. 原理（重要）

opencode v2 默认会为当前用户跑**一个共享后台服务**，所有 `opencode` 客户端自动接入。
本项目把这个共享服务**固定到 `127.0.0.1:4096`**，所以你**直接敲 `opencode` 照常工作**，而且所有 session 都在固定地址上，便于隧道与 App 访问。

固定端口（只需做一次）：

```bash
opencode service set hostname 127.0.0.1
opencode service set port 4096
```

> 注意：每次 `service set` 都会**重启后台服务**（会短暂断开正在运行的 TUI，重连即可）。
> 配置持久化在 `~/.config/opencode/service.json`，重启后仍生效。
> 确认：`opencode service status` 应输出 `http://127.0.0.1:4096`。

查看 App 要用的密码：

```bash
python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/opencode/service.json')))['password'])"
```

## 1. 安装后台服务

```bash
cd ~/Projects/Opencode-Pocket
./infra/mac/install-mac.sh
```

会创建 `~/.config/opencode-pocket/env` 并把三个 launchd 服务渲染到 `~/Library/LaunchAgents/`：

| Label | 作用 |
|---|---|
| `ai.opencode.pocket.serve` | 登录时确保共享服务已启动 |
| `ai.opencode.pocket.tunnel` | `ssh -R` 反向隧道到 VPS |
| `ai.opencode.pocket.pocketd` | 订阅事件 → 通知 |

编辑 `~/.config/opencode-pocket/env` 填入 `VPS_HOST` / `VPS_USER` / `NTFY_TOPIC`。
其中 `VPS_TUNNEL_BIND=0.0.0.0` 表示把转发绑到 VPS（Caddy 容器可经 `host.docker.internal` 访问）；
该端口不对公网开放，仅 Docker 网段可达。详见 `docs/vps-setup.md`。

## 2. 手动控制

```bash
launchctl list | grep opencode.pocket
launchctl kickstart -k gui/$(id -u)/ai.opencode.pocket.tunnel
launchctl bootout   gui/$(id -u)/ai.opencode.pocket.pocketd
```

## 3. 验证

```bash
PW=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/opencode/service.json')))['password'])")

# 本机
curl -u opencode:$PW http://127.0.0.1:4096/api/info

# 经隧道 + Caddy（公网，需已完成 VPS 侧部署与 DNS）
curl -u opencode:$PW https://pocket.example.com/api/info

# 正在运行的 session
curl -u opencode:$PW http://127.0.0.1:4096/api/session/active
```

## 4. 关于 VSCode 扩展

旧的 `sst-dev.opencode` 扩展执行 `opencode --port <随机>`（v1 语法，v2 顶层无此参数），会干扰聚合。
推荐：**在 VSCode 终端里直接 `opencode`**（走共享服务）；或 source `infra/mac/oc.sh` 之后用 `oc`。
不使用旧扩展的“打开终端”按钮即可。
