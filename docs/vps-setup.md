# VPS 侧部署（your-vps-host）

本机（VPS）已用 **Docker + Caddy 容器**（`docker-caddy-1`, caddy:2）统一管理 `example.com` 下所有站点。
**不要另装 Caddy**（80/443 已被占用）。只需三步把它接进来。

## 前置

- DNS：`pocket.example.com` A 记录 → `your-vps-host`
- Caddyfile：`/home/ubuntu/zxLumen-Blog/docker/Caddyfile`（由 compose 挂载）
- Caddy 容器已配 `extra_hosts: ["host.docker.internal:host-gateway"]`

## 1. 允许反向转发绑定到 Docker 网关

```bash
sudo sed -i -E 's/^[[:space:]]*#?[[:space:]]*GatewayPorts.*/GatewayPorts clientspecified/I' /etc/ssh/sshd_config
# 若原本没有该行：echo 'GatewayPorts clientspecified' | sudo tee -a /etc/ssh/sshd_config
sudo sshd -t && sudo systemctl reload ssh
```

## 2. 放行容器访问宿主机 4096（仅 Docker 网段，不暴露公网）

```bash
sudo ufw allow from 172.16.0.0/12 to any port 4096 proto tcp
```

> 原理：VPS 的 `INPUT` 策略是 DROP；容器访问宿主机端口属于 INPUT。参照现有 `mail` 站点的做法（它放行了 8443）。

## 3. 追加站点并重载 Caddy

把 [`../infra/vps/Caddyfile`](../infra/vps/Caddyfile) 的片段追加到 Caddyfile 末尾：

```bash
cat >> /home/ubuntu/zxLumen-Blog/docker/Caddyfile <<'CADDY'

pocket.{$DOMAIN} {
	encode zstd gzip
	header {
		X-Content-Type-Options nosniff
		-Server
	}
	reverse_proxy host.docker.internal:4096 {
		flush_interval -1
	}
}
CADDY

sudo docker exec docker-caddy-1 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo docker exec docker-caddy-1 caddy reload   --config /etc/caddy/Caddyfile --adapter caddyfile
```

Caddy 会自动为该域名签发 Let's Encrypt 证书。

## 验证（在 Mac 上）

```bash
PW=$(python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/opencode/service.json')))['password'])")
curl -u opencode:$PW https://pocket.example.com/api/info   # 期望 200 + version 2.0.x
```

## 架构要点

- Mac 侧 ssh -R 把本机 4096 绑到 VPS 的 `0.0.0.0:4096`（Caddy 容器经 `host.docker.internal` 访问）。
- Caddy 容器经 `host.docker.internal:4096`(=172.17.0.1) 访问 Mac 的 opencode 服务。
- 公网只开 443；4096 仅对 Docker 网段开放（ufw 限制，实测公网不可达）。
- 认证由 opencode 自身提供（HTTP Basic）。
