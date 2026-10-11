# VPS 侧部署（your-vps-host，Ubuntu）

## 前置

- 域名 `pocket.example.com` 的 A 记录指向 `your-vps-host`。
- 安全组/防火墙放行 80、443（Caddy 签发证书需要 80；正常代理走 443）。
- 无需备案。

## 1. 安装 Caddy

```bash
sudo apt update
sudo apt install -y debian-keyring debian-archive-keyring apt-transport-https curl
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | sudo gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' | sudo tee /etc/apt/sources.list.d/caddy-stable.list
sudo apt update && sudo apt install -y caddy
```

## 2. 写入 Caddyfile

```bash
cd ~/Projects/Opencode-Pocket    # 在 Mac 上；或把 infra/vps/Caddyfile scp 到 VPS
scp infra/vps/Caddyfile ubuntu@your-vps-host:/tmp/Caddyfile
ssh ubuntu@your-vps-host 'sudo cp /tmp/Caddyfile /etc/caddy/Caddyfile && sudo systemctl restart caddy && sudo systemctl status caddy --no-pager'
```

或用脚本：

```bash
./infra/vps/install-vps.sh
```

## 3. 隧道

隧道由 Mac 侧 launchd 服务 `ai.opencode.pocket.tunnel` 建立（Mac 出站 ssh -R）。
VPS 上无需常驻进程，只需 SSH 服务可用。

验证（VPS 上）：

```bash
curl -su opencode:$PW http://127.0.0.1:4096/api/info
```

## 4. 加固（可选）

- 限制 SSH 来源：`ufw allow from <你的常用网段> to any port 22`。
- fail2ban。
- Caddy 层 IP 白名单（在 Caddyfile 中加 `@allow` 指令）。
