# 前台/后台判断（供 auto-renew.sh source）。
# 依赖: DEVICE_UDID, BUNDLE_ID, APP_PROC_MATCH
# app_scene_blocking: 返回 0 = 应顺延（前台/未知），1 = 可以续签（后台/未运行/锁屏）。
# 结果说明放在全局 APP_SCENE_REASON。


# ---------------------------------------------------------------------------
# 签名保护：Mac 锁屏时 Xcode 读不到 data-protection keychain，
# 会把 Apple ID 当成损坏并删除。签名构建前必须检查锁屏与账号凭据。
# ---------------------------------------------------------------------------

screen_is_locked() {
  ioreg -n Root -d1 2>/dev/null | grep -q '"CGSSessionScreenIsLocked"=Yes'
}


# 返回 0 = 可以安全签名（并已启动 caffeinate）；1 = 应跳过。
# 原因放在 SIGNING_GUARD_REASON。
signing_guard() {
  SIGNING_GUARD_REASON=""
  if screen_is_locked; then
    SIGNING_GUARD_REASON="Mac 锁屏"
    return 1
  fi
  # 构建期间保持显示器不睡眠，避免中途锁屏触发 Xcode 删账号。
  if command -v caffeinate >/dev/null 2>&1; then
    caffeinate -u -d -w $$ >/dev/null 2>&1 &
  fi
  return 0
}

scene_app_running() {
  local out
  out="$(xcrun devicectl device info processes --device "$DEVICE_UDID" -t 10 2>/dev/null || true)"
  grep -q "/${APP_PROC_MATCH}/" <<<"$out"
}

scene_lock_state() {
  # devicectl 的 JSON 里没有“当前是否锁屏”，终端输出才有；优先解析文本。
  local out
  out="$(xcrun devicectl device info lockState --device "$DEVICE_UDID" -t 10 2>/dev/null || true)"
  case "$out" in
    *unlocked*) echo "unlocked"; return ;;
    *locked*)   echo "locked";   return ;;
  esac
  echo "unknown"
}

scene_marker() {
  local tmp; tmp="$(mktemp -d)"
  local dest="$tmp/ios-scene.json"
  local ok=0
  if ! xcrun devicectl device copy from --device "$DEVICE_UDID" \
      --domain-type appDataContainer --domain-identifier "$BUNDLE_ID" \
      --source "Documents/ios-scene.json" --destination "$dest" -t 15 >/dev/null 2>&1; then
    rm -rf "$tmp"; return 1
  fi
  [ -f "$dest" ] || { rm -rf "$tmp"; return 1; }
  local file="$dest"
  python3 - "$file" <<'PY' 2>/dev/null
import json, sys
from datetime import datetime, timezone
try:
    d = json.load(open(sys.argv[1]))
except Exception:
    raise SystemExit(1)
state = str(d.get("state", ""))
at = str(d.get("at", ""))
if not state:
    raise SystemExit(1)
try:
    dt = datetime.fromisoformat(at.replace("Z", "+00:00"))
    age = int((datetime.now(timezone.utc) - dt).total_seconds())
except Exception:
    age = 999999
print(state, age)
PY
  rm -rf "$tmp"
}

app_scene_blocking() {
  APP_SCENE_REASON=""
  if ! scene_app_running; then
    APP_SCENE_REASON="未运行"
    return 1
  fi

  local info state age
  if info="$(scene_marker)"; then
    state="${info%% *}"
    age="${info##* }"
    age="${age:-999999}"
    case "$state" in
      foreground)
        if [ "$age" -le 180 ]; then
          APP_SCENE_REASON="前台运行（${age}s 前）"
          return 0
        fi
        ;;
      inactive)
        if [ "$age" -le 60 ]; then
          APP_SCENE_REASON="刚切出（${age}s 前）"
          return 0
        fi
        ;;
      background)
        APP_SCENE_REASON="后台挂起"
        return 1
        ;;
    esac
  fi

  local lock; lock="$(scene_lock_state)"
  if [ "$lock" = "locked" ]; then
    APP_SCENE_REASON="锁屏（无前台）"
    return 1
  fi
  APP_SCENE_REASON="前台状态未知（保守顺延）"
  return 0
}
