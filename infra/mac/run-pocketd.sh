#!/usr/bin/env bash
# Run pocketd (event -> notification daemon). Run by launchd.
set -euo pipefail
ENV_FILE="${OPENCODE_POCKET_ENV:-$HOME/.config/opencode-pocket/env}"
if [[ -f "$ENV_FILE" ]]; then
  set -a; # shellcheck disable=SC1090
  . "$ENV_FILE"; set +a
fi
NODE_BIN="${NODE_BIN:-$(command -v node)}"
: "${NODE_BIN:?node not found; set NODE_BIN in env file}"
REPO="${POCKET_REPO:-$HOME/Projects/Opencode-Pocket}"
exec "$NODE_BIN" "$REPO/pocketd/src/index.js"
