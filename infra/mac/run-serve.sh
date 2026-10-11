#!/usr/bin/env bash
# Ensure the opencode shared background service is running (pinned to 127.0.0.1:4096).
# Run by launchd at login. The service is what plain `opencode` attaches to, so this
# keeps remote access available even before any TUI is opened.
set -uo pipefail
ENV_FILE="${OPENCODE_POCKET_ENV:-$HOME/.config/opencode-pocket/env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a; # shellcheck disable=SC1090
  . "$ENV_FILE"; set +a
fi
OC_BIN="${OC_BIN:-$HOME/.opencode/bin/opencode}"
exec "$OC_BIN" service start
