#!/usr/bin/env bash
# Install Opencode-Pocket Mac services.
#
# Model: the *shared* opencode background service is pinned to 127.0.0.1:4096,
# so plain `opencode` (your normal habit) already lands there. We only add:
#   - a login job that ensures the service is up
#   - the reverse tunnel to the VPS
#   - pocketd (event -> notification)
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
  cat > "$ENV_FILE" <<EOF
# Opencode-Pocket — Mac environment (keep private)
# The opencode password is read from ~/.config/opencode/service.json by pocketd;
# the iOS app needs it too — print it with:
#   python3 -c "import json,os;print(json.load(open(os.path.expanduser('~/.config/opencode/service.json')))['password'])"

POCKET_REPO=$REPO
NODE_BIN=$NODE_BIN
OC_BIN=$OC_BIN

# The shared service is pinned to this address (see docs/mac-setup.md).
OPENCODE_URL=http://127.0.0.1:4096
OPENCODE_SERVER_USERNAME=opencode

# Reverse tunnel to VPS (Mac -> VPS, outbound)
VPS_HOST=your-vps-host
VPS_USER=ubuntu
VPS_SSH_PORT=22
TUNNEL_PORT=4096
# Address on the VPS to bind the forwarded port. 0.0.0.0 is required so the Caddy
# container can reach it; it is NOT public because ufw only allows 172.16.0.0/12 to hit 4096.
VPS_TUNNEL_BIND=0.0.0.0

# pocketd
POCKETD_PORT=8788
NTFY_URL=https://ntfy.sh
NTFY_TOPIC=opencode-pocket-CHANGE-ME
NTFY_TOKEN=
POCKET_URL_SCHEME=opencodepocket
EOF
  chmod 600 "$ENV_FILE"
  echo "Created $ENV_FILE"
else
  echo "Keeping existing $ENV_FILE"
fi

# Verify the shared service is pinned to 4096, warn otherwise.
CUR_PORT="$("$OC_BIN" service get port 2>/dev/null | tr -d '[:space:]')"
if [[ "$CUR_PORT" != "4096" ]]; then
  echo
  echo "WARNING: shared service port is '${CUR_PORT:-<unset>}', expected 4096."
  echo "Pin it (this restarts the background service) with:"
  echo "  opencode service set hostname 127.0.0.1 && opencode service set port 4096"
  echo
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
echo "App password: python3 -c \"import json,os;print(json.load(open(os.path.expanduser('~/.config/opencode/service.json')))['password'])\""
echo "Verify local: curl -u opencode:\$(cat /dev/null) http://127.0.0.1:4096/api/info"
