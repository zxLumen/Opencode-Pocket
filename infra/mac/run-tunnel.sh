#!/usr/bin/env bash
# Reverse tunnel Mac:PORT -> VPS:PORT (outbound). Retries on failure. Run by launchd.
set -uo pipefail
ENV_FILE="${OPENCODE_POCKET_ENV:-$HOME/.config/opencode-pocket/env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a; # shellcheck disable=SC1090
  . "$ENV_FILE"; set +a
fi
PORT="${OPENCODE_POCKET_PORT:-4096}"
: "${VPS_HOST:?VPS_HOST must be set}"
: "${VPS_USER:?VPS_USER must be set}"
SSH_PORT="${VPS_SSH_PORT:-22}"

while true; do
  echo "[tunnel] $(date '+%F %T') connecting $VPS_USER@$VPS_HOST -R $PORT:127.0.0.1:$PORT"
  ssh -N \
    -p "$SSH_PORT" \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -R "${PORT}:127.0.0.1:${PORT}" \
    "${VPS_USER}@${VPS_HOST}"
  code=$?
  echo "[tunnel] $(date '+%F %T') ssh exited ($code); retry in 5s"
  sleep 5
done
