# VPS 侧部署自建 anisette-v3

给 SideStore 提供「假 Mac」的 anisette 数据，避免免费 Apple ID 被锁定。
SideStore 签名/续签**仍在手机上做**，这里只承担数据源。

## 1. 起容器

```bash
cd infra/vps/anisette
sudo docker compose up -d          # 镜像 dadoum/anisette-v3-server，端口 6969
sudo docker compose ps              # 看状态
```

## 2. 放行 Docker 网段访问 6969（不暴露公网）

```bash
sudo ufw allow from 172.16.0.0/12 to any port 6969 proto tcp
```

> 原理和已有 4096 规则一样：VPS INPUT 默认 DROP，只有 Docker 网段能经
> `host.docker.internal:6969`(=172.17.0.1) 打到宿主机端口；公网进不来。

## 3. Caddy 追加段（见 `../Caddyfile`）

把仓库里 `anisette.{$DOMAIN}` 那一段追加到
`/home/ubuntu/zxLumen-Blog/docker/Caddyfile` 末尾，然后：

```bash
sudo docker exec docker-caddy-1 caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
sudo docker exec docker-caddy-1 caddy reload   --config /etc/caddy/Caddyfile --adapter caddyfile
```

**必须替换** `CHANGE-ME-SECRET-PATH` 为一串随机长路径（如
`/9f3k2-v4xz/a2-q7n`），并在下面第 5 步和 `docs/anisette-servers.json` 里保持一致。
对了再确认 `anisette.{$DOMAIN}` 有 DNS 解析到本机（一般走通配符）。

## 4. 验证

```bash
curl -i "https://anisette.example.com/CHANGE-ME-SECRET-PATH" | head -5   # 期望 200 + JSON
curl -i "https://anisette.example.com/other" | head -3                   # 期望 404
```

## 5. SideStore 指向它（手机端）

1. 把 `docs/anisette-servers.json` 里的 `address` 改成真实地址（含你的密钥路径）。
2. SideStore → 设置 → 拉到最下面 **Anisette Servers** → 把 **List URL**
   换成 `https://zxlumen.github.io/Opencode-Pocket/anisette-servers.json`
   （或自有托管地址）。
3. 点 **Refresh Servers** → 选择 `my-VPS (anisette-v3)`。

## 安全说明

- anisette 服务不含你的 Apple ID 凭据（只是生成设备认证数据），但**别公开**。
- 随机长路径 + 404 兜底只是防随手扫图；端口 6969 已被 ufw 限制为 Docker 网段。

## 故障

- JSON 无响应/401：确认路径与列表地址完全一致；Caddy reload 是否成功。
- 换系统/重置后配对文件失效请重导，与 anisette 无关。