#!/usr/bin/env bash
# 安装续签看门狗（launchd，每 6 小时跑一次 + 登录时跑一次）。
# 与 auto-renew 相互独立：续签脚本自己挂掉时，看门狗仍会报警。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LABEL="cn.zxlumen.opencodepocket.renewwatch"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
STATE_DIR="$ROOT/.build"
mkdir -p "$HOME/Library/LaunchAgents" "$STATE_DIR"
chmod +x "$ROOT/scripts/renew-watchdog.sh" 2>/dev/null || true

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
        <string>$ROOT/scripts/renew-watchdog.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>21600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:/opt/homebrew/bin</string>
    </dict>
    <key>StandardOutPath</key>
    <string>$STATE_DIR/renew-watchdog.launchd.log</string>
    <key>StandardErrorPath</key>
    <string>$STATE_DIR/renew-watchdog.launchd.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "installed: $PLIST"
launchctl list | grep "$LABEL" || true
