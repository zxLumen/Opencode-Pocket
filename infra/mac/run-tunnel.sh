#!/usr/bin/env bash
# Reverse tunnel Mac:PORT -> VPS:PORT (outbound). Retries on failure. Run by launchd.
set -uo pipefail
ENV_FILE="${OPENCODE_POCKET_ENV:-$HOME/.config/opencode-pocket/env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a; # shellcheck disable=SC1090
  . "$ENV_FILE"; set +a
fi
PORT="${TUNNEL_PORT:-${OPENCODE_POCKET_PORT:-4096}}"
POCKETD_PORT="${POCKETD_TUNNEL_PORT:-8788}"
BIND="${VPS_TUNNEL_BIND:-0.0.0.0}"   # bind on the VPS; keep it non-public via ufw (see docs/vps-setup.md)
: "${VPS_HOST:?VPS_HOST must be set}"
: "${VPS_USER:?VPS_USER must be set}"
SSH_PORT="${VPS_SSH_PORT:-22}"

while true; do
  echo "[tunnel] $(date '+%F %T') connecting $VPS_USER@$VPS_HOST -R $BIND:$PORT / $POCKETD_PORT"
  ssh -N \
    -p "$SSH_PORT" \
    -o ControlMaster=no \
    -o ControlPath=none \
    -o ServerAliveInterval=30 \
    -o ServerAliveCountMax=3 \
    -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=accept-new \
    -R "${BIND}:${PORT}:127.0.0.1:${PORT}" \
    -R "${BIND}:${POCKETD_PORT}:127.0.0.1:${POCKETD_PORT}" \
    "${VPS_USER}@${VPS_HOST}"
  code=$?
  echo "[tunnel] $(date '+%F %T') ssh exited ($code); retry in 5s"
  sleep 5
done
