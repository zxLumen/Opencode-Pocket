#!/usr/bin/env bash
# 服务器侧「拉取式」自动部署(由 cron 每 3 分钟执行一次)。
#
# 为什么不用 CI 直接 SSH:runner(动态 IP)连云安全组的 22 端口常被丢弃 → CI 的
# SSH 步骤会超时。改为服务器主动轮询:本仓库 main 的最新 SHA → 若 GHCR 已有对应
# 镜像且与上次部署不同,则调用与 CI 完全相同的 ci-run.sh 完成部署(同样会同步
# 「不进镜像」的服务器侧配置)。
#
# crontab(ubuntu 用户,本机即为线上服务器):
#   */3 * * * * cd /home/ubuntu/Opencode-Pocket/sandbox && ./auto-deploy.sh >> ./auto-deploy.log 2>&1
set -uo pipefail
cd "$(dirname "$0")" || exit 1
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

REPO_URL="${REPO_URL:-https://github.com/zxLumen/Opencode-Pocket.git}"
IMAGE_BASE="${IMAGE_BASE:-ghcr.io/zxlumen/opencode-pocket-sandbox}"
BRANCH="${BRANCH:-main}"
STATE="./.last-deployed"
LOCK="./.auto-deploy.lock"

log() { echo "[$(date -Is)] $*"; }

# 互斥:上一轮仍在跑就跳过
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
  exit 0
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT

REMOTE="$(git ls-remote "$REPO_URL" "refs/heads/$BRANCH" 2>/dev/null | awk '{print $1}')"
[ -n "$REMOTE" ] || { log "resolve remote failed"; exit 0; }

LAST="$(cat "$STATE" 2>/dev/null || true)"
[ "$REMOTE" = "$LAST" ] && exit 0

# 镜像还没构建好(如纯文档提交不触发构建)→ 记下但不部署,下轮再判断
if ! docker manifest inspect "$IMAGE_BASE:$REMOTE" >/dev/null 2>&1; then
  log "image not ready: $REMOTE (skip)"
  exit 0
fi

log "deploying $REMOTE (last=${LAST:-none})"
if SSH_ORIGINAL_COMMAND="$REMOTE" ./ci-run.sh >> ./auto-deploy.log 2>&1; then
  echo "$REMOTE" > "$STATE"
  log "ok: $REMOTE"
else
  log "FAIL: $REMOTE (see auto-deploy.log)"
fi
