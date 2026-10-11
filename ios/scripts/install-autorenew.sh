#!/usr/bin/env bash
# 安装常驻自动续签任务（launchd，每 30 分钟检查一次）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="cn.zxlumen.opencodepocket.autorenew"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$ROOT/.build"
mkdir -p "$HOME/Library/LaunchAgents" "$STATE_DIR"

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$LABEL</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>$ROOT/scripts/auto-renew.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>1800</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$STATE_DIR/auto-renew.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$STATE_DIR/auto-renew.launchd.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $PLIST"
launchctl list | grep "$LABEL" || true
