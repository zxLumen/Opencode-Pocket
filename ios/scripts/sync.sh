#!/usr/bin/env bash
# 真机部署：构建 → 安装 → 启动（免费个人账号，automatic signing）。
# 注意：需要 iPhone 对 Mac 可达。自家网络若为 SG659HZ 光猫，5G↔5G 被隔离，
#       请让 Mac 与 iPhone 处于不同频段（通常 Mac 连 2.4G / iPhone 连 5G）。
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

PROJECT="OpencodePocket.xcodeproj"
SCHEME="OpencodePocket"
BUNDLE_ID="cn.zxlumen.opencodepocket"
DEVICE_UDID="${DEVICE_UDID:-00008030-000804100CE8802E}"
DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-T8TG4WAR43}"
APP=".build/device/Build/Products/Debug-iphoneos/OpencodePocket.app"

source "$ROOT/scripts/scene-guard.sh"

if screen_is_locked; then
  echo "!! Mac 锁屏中：先解锁再构建，否则 Xcode 会删除 Apple ID"
  exit 2
fi
if ! xcode_account_present; then
  echo "!! Xcode 账号凭据缺失：请到 Xcode → Settings → Accounts 重新添加 Apple ID"
  exit 2
fi
caffeinate -u -d -w $$ >/dev/null 2>&1 &


if [ ! -d "$PROJECT" ]; then
  echo "==> 生成 Xcode 工程"
  command -v xcodegen >/dev/null || { echo "需要 xcodegen"; exit 1; }
  xcodegen generate
fi

echo "==> 真机构建 ($DEVICE_UDID)"
xcodebuild -project "$PROJECT" -scheme "$SCHEME" \
  -destination "id=$DEVICE_UDID" -derivedDataPath .build/device build \
  CODE_SIGN_STYLE=Automatic CODE_SIGNING_ALLOWED=YES -allowProvisioningUpdates \
  DEVELOPMENT_TEAM="$DEVELOPMENT_TEAM"

echo "==> 真机安装并启动"
xcrun devicectl device install app --device "$DEVICE_UDID" "$APP"
xcrun devicectl device process terminate --device "$DEVICE_UDID" "$BUNDLE_ID" 2>/dev/null || true
xcrun devicectl device process launch --device "$DEVICE_UDID" "$BUNDLE_ID"

echo "==> 完成"

# 部署过程会切换 Wi-Fi（含 2.4G/5G），可能打断反向隧道；收尾重建一次。
launchctl kickstart -k "gui/$(id -u)/ai.opencode.pocket.tunnel" 2>/dev/null || true
