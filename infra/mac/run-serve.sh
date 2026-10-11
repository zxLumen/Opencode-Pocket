#!/usr/bin/env bash
# Start the dedicated opencode server on a fixed port (foreground; run by launchd).
set -euo pipefail
ENV_FILE="${OPENCODE_POCKET_ENV:-$HOME/.config/opencode-pocket/env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a; # shellcheck disable=SC1090
  . "$ENV_FILE"; set +a
fi
OC_BIN="${OC_BIN:-$HOME/.opencode/bin/opencode}"
PORT="${OPENCODE_POCKET_PORT:-4096}"
: "${OPENCODE_SERVER_PASSWORD:?OPENCODE_SERVER_PASSWORD must be set (see ~/.config/opencode-pocket/env)}"
export OPENCODE_SERVER_USERNAME="${OPENCODE_SERVER_USERNAME:-opencode}"
export OPENCODE_SERVER_PASSWORD
exec "$OC_BIN" serve --hostname 127.0.0.1 --port "$PORT"
