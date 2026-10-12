#!/usr/bin/env bash
# 部署访客沙盒栈(在服务器 ~/Opencode-Pocket/sandbox 内运行)。
# 从 GHCR 拉取新镜像 → 无损 reload 边缘 Caddy → up -d → 回收旧镜像。
#
# 用法:
#   ./deploy.sh <git-sha>     # CI / auto-deploy 使用(镜像 tag 用该 sha)
#   ./deploy.sh               # 手动:拉 latest
set -euo pipefail
cd "$(dirname "$0")"

IMAGE_TAG="${1:-${IMAGE_TAG:-latest}}"
export OPENCODE_SANDBOX_TAG="${IMAGE_TAG}"

[[ "${EUID}" -eq 0 ]] || SUDO="sudo -n"
echo "[sandbox-deploy] tag=${IMAGE_TAG} (工作目录: $(pwd))"

# sudo 默认 env_reset 会清掉变量,用 env 显式传回 compose
${SUDO:-} env OPENCODE_SANDBOX_TAG="${OPENCODE_SANDBOX_TAG}" docker compose pull opencode-play

# Caddyfile 是 bind mount:内容变了不会重启容器 → 先尝试无损 reload(失败才重建容器)。
# ⚠️ caddy reload 是一个**新的 exec 进程**,拿不到 entrypoint 在运行时导出的
# SANDBOX_UPSTREAM_AUTH;若直接 reload,{$SANDBOX_UPSTREAM_AUTH} 会被替换成空 →
# 上游鉴权失效(全站 401)。故用 Config.Env 里的 PLAYGROUND_SERVER_PASSWORD 现算后注入。
if ${SUDO:-} docker compose ps --status running --services 2>/dev/null | grep -q '^sandbox-caddy$'; then
  ${SUDO:-} docker compose exec -T sandbox-caddy sh -c \
    'export SANDBOX_UPSTREAM_AUTH="Basic $(printf "opencode:%s" "$PLAYGROUND_SERVER_PASSWORD" | base64 | tr -d "\n")"; caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile' \
    || ${SUDO:-} env OPENCODE_SANDBOX_TAG="${OPENCODE_SANDBOX_TAG}" docker compose up -d --force-recreate sandbox-caddy
fi

${SUDO:-} env OPENCODE_SANDBOX_TAG="${OPENCODE_SANDBOX_TAG}" docker compose up -d

# 回收 12 小时前的旧镜像(在用的不受影响)
${SUDO:-} docker image prune -af --filter until=12h

${SUDO:-} docker compose ps
echo "[sandbox-deploy] 完成"
