#!/usr/bin/env bash
# Install Opencode-Pocket Mac services (serve, tunnel, pocketd) as launchd agents.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CONF_DIR="$HOME/.config/opencode-pocket"
STATE_DIR="$HOME/.local/state/opencode-pocket"
LA_DIR="$HOME/Library/LaunchAgents"
ENV_FILE="$CONF_DIR/env"

OC_BIN="$(command -v opencode || true)"
[[ -n "$OC_BIN" ]] || { echo "ERROR: opencode not found in PATH" >&2; exit 1; }
NODE_BIN="$(command -v node || true)"
[[ -n "$NODE_BIN" ]] || { echo "ERROR: node not found in PATH" >&2; exit 1; }

mkdir -p "$CONF_DIR" "$STATE_DIR" "$LA_DIR"
chmod 700 "$CONF_DIR" "$STATE_DIR"

if [[ ! -f "$ENV_FILE" ]]; then
  PW="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
  cat > "$ENV_FILE" <<EOF
# Opencode-Pocket — Mac environment (keep private)
OPENCODE_SERVER_USERNAME=opencode
OPENCODE_SERVER_PASSWORD=$PW
OPENCODE_POCKET_PORT=4096

POCKET_REPO=$REPO
NODE_BIN=$NODE_BIN
OC_BIN=$OC_BIN

# Reverse tunnel to VPS (Mac -> VPS, outbound)
VPS_HOST=your-vps-host
VPS_USER=ubuntu
VPS_SSH_PORT=22

# pocketd
OPENCODE_URL=http://127.0.0.1:4096
POCKETD_PORT=8788
NTFY_URL=https://ntfy.sh
NTFY_TOPIC=opencode-pocket-CHANGE-ME
NTFY_TOKEN=
POCKET_URL_SCHEME=opencodepocket
EOF
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE (edit NTFY_TOPIC etc.)"
else
  echo "Keeping existing $ENV_FILE"
fi

render() {
  local src="$1" dst="$2"
  sed -e "s#__REPO__#$REPO#g" -e "s#__HOME__#$HOME#g" "$src" > "$dst"
  chmod 644 "$dst"
}

chmod +x "$REPO/infra/mac/"*.sh

for name in serve tunnel pocketd; do
  render "$REPO/infra/mac/ai.opencode.pocket.$name.plist" "$LA_DIR/ai.opencode.pocket.$name.plist"
done

UID_NUM="$(id -u)"
for name in serve tunnel pocketd; do
  launchctl bootout "gui/$UID_NUM/ai.opencode.pocket.$name" 2>/dev/null || true
  launchctl bootstrap "gui/$UID_NUM" "$LA_DIR/ai.opencode.pocket.$name.plist"
  echo "loaded ai.opencode.pocket.$name"
done

echo
echo "Logs: $STATE_DIR"
echo "Verify: curl -u opencode:\$OPENCODE_SERVER_PASSWORD http://127.0.0.1:4096/api/info"
