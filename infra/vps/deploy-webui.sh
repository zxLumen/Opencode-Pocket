#!/usr/bin/env bash
# 把 opencode WebUI 的本地构建同步到 pocket 站点的 Caddy 静态目录，并热加载 Caddy。
#
# 依赖：
#   - opencode 源码在 $OPENCODE_DIR（默认 ~/Projects/opencode-pocket-wt）
#   - 已在该仓库执行过 `node node_modules/vite/bin/vite.js build`（apps 的 dist 已生成）
#   - Caddy 站点文件 docker/caddy/sites/pocket.caddy 已按 infra/vps/Caddyfile 的 pocket 段配置
#
# 用法： ./deploy-webui.sh [dist目录]
set -euo pipefail

SRC="${1:-$HOME/Projects/opencode-pocket-wt/packages/app/dist}"
DEST="/home/ubuntu/zxLumen-Blog/docker/site-content/pocket-app"
CADDY_CONTAINER="${CADDY_CONTAINER:-docker-caddy-1}"
DOMAIN="${POCKET_DOMAIN:-pocket.zxlumen.cn}"

if [[ ! -f "$SRC/index.html" ]]; then
  echo "找不到 $SRC/index.html；先在 opencode 仓库跑 app 构建" >&2
  exit 1
fi

mkdir -p "$DEST"
# sourcemap 不对外，省 50MB。
rsync -a --delete --exclude='*.map' "$SRC/" "$DEST/"

docker exec "$CADDY_CONTAINER" caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null
docker exec "$CADDY_CONTAINER" caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile >/dev/null

code=$(curl -s -o /dev/null -w '%{http_code}' "https://$DOMAIN/")
echo "deployed -> https://$DOMAIN/ ($code)"
