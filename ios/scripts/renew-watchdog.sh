#!/usr/bin/env bash
# 续签看门狗（独立于 auto-renew.sh）。
#
# 为什么需要独立脚本：2026-10-11 ~ 10-19 期间 auto-renew.sh 在 183 行因
# `set -u` + 算术表达式里的裸变量直接退出，**一次都没跑成功**，8 天后
# 描述文件过期、App 打不开才发现。续签脚本自己坏了就没法报警，所以再放一个
# 独立的小任务来盯它。
#
# 检查项（每个受监控的 App）：
#   1) 描述文件剩余天数（<= 阈值 报警；找不到也报警）
#   2) 续签日志里最近的 `!!` 异常（默认 24h 内）
#   3) lastRenewAt 新鲜度（超过 6.5 天没成功续签就报警）
#   4) launchd 任务是否还在
# 通知：terminal-notifier（HAP 下可靠）；每项检查有 12h 去重。
#
# 用法：renew-watchdog.sh [--verbose]
set -uo pipefail
[ -n "${BASH_VERSION:-}" ] || exec /bin/bash "$0" "$@"

MODE="${1:-}"
THIS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POCKET_IOS="$(cd "$THIS_DIR/.." && pwd)"          # .../Opencode-Pocket/ios
PROJECTS_ROOT="$(cd "$POCKET_IOS/../.." && pwd)"  # .../Projects（各项目同级）

DAYS_ALERT_THRESHOLD="${DAYS_ALERT_THRESHOLD:-3}"     # 剩余 <= 3 天就提醒
ERR_LOOKBACK_HOURS="${ERR_LOOKBACK_HOURS:-24}"        # 日志里多久内出现 !! 算异常
RENEW_STALE_DAYS="${RENEW_STALE_DAYS:-6.5}"           # 多久没成功续签算异常
NOTIFY_GAP="${NOTIFY_GAP:-43200}"                     # 同类提醒间隔（12h）
STATE_DIR="$THIS_DIR/../.build"
LOG="$STATE_DIR/renew-watchdog.log"
STATE="$STATE_DIR/renew-watchdog.state"
mkdir -p "$STATE_DIR"

log() { echo "[$(date '+%F %T')] $*"; }

# ---- 通知通道（与 auto-renew.sh 同源：terminal-notifier 优先）----
TERMINAL_NOTIFIER="${TERMINAL_NOTIFIER:-}"
if [ -z "$TERMINAL_NOTIFIER" ]; then
  for cand in \
    "$HOME/.cache/opencode/packages/opencode-smart-voice-notify@latest/node_modules/node-notifier/vendor/mac.noindex/terminal-notifier.app/Contents/MacOS/terminal-notifier" \
    "$HOME/Library/Application Support/Yijing64/terminal-notifier.app/Contents/MacOS/terminal-notifier" \
    "/opt/homebrew/bin/terminal-notifier" \
    "/usr/local/bin/terminal-notifier"; do
    if [ -x "$cand" ]; then TERMINAL_NOTIFIER="$cand"; break; fi
  done
fi

read_state() { [ -f "$STATE" ] || return 0; sed -n "s/^$1=//p" "$STATE" 2>/dev/null || true; }
write_state() {
  touch "$STATE" 2>/dev/null || return 0
  grep -v "^$1=" "$STATE" >"$STATE.tmp" 2>/dev/null || true
  mv "$STATE.tmp" "$STATE" 2>/dev/null || true
  echo "$1=$2" >>"$STATE" 2>/dev/null || true
}

# 同类提醒去重：key 决定间隔
alert_once() {
  local key="$1" title="$2" msg="$3" last now
  last="$(read_state "$key")"; now=$(date +%s)
  if [ -n "$last" ] && [ $((now - last)) -lt "$NOTIFY_GAP" ]; then
    log "（去重）${title}：${msg}"
    return 0
  fi
  write_state "$key" "$now"
  log "报警：${title}：${msg}"
  if [ -n "$TERMINAL_NOTIFIER" ] && [ -x "$TERMINAL_NOTIFIER" ]; then
    "$TERMINAL_NOTIFIER" -title "$title" -message "$msg" >/dev/null 2>&1 || true
  else
    osascript -e "display notification \"$msg\" with title \"$title\"" >/dev/null 2>&1 || true
  fi
  return 0
}

profile_days_left() {   # $1=bundle id  → 打印天数（可为负），找不到打印空
  local bid="$1" d f name exp_raw
  for d in "$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles" \
           "$HOME/Library/MobileDevice/Provisioning Profiles"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.mobileprovision; do
      [ -f "$f" ] || continue
      name="$(security cms -D -i "$f" 2>/dev/null | plutil -extract Name raw - 2>/dev/null || true)"
      case "$name" in *"$bid"*) ;; *) continue ;; esac
      exp_raw="$(security cms -D -i "$f" 2>/dev/null | plutil -extract ExpirationDate raw - 2>/dev/null || true)"
      [ -n "$exp_raw" ] || continue
      local ep; ep="$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$exp_raw" "+%s" 2>/dev/null || echo 0)"
      awk -v a="$ep" -v b="$(date +%s)" 'BEGIN{printf "%.2f", (a-b)/86400}'
      return 0
    done
  done
  return 0
}

check_app() {   # $1=label $2=project_dir $3=bundle_id $4=显示名
  local label="$1" dir="$2" bid="$3" disp="$4"
  local days logf statef last_renew now stale_after

  [ -d "$dir" ] || { log "跳过（目录不存在）：$disp ($dir)"; return 0; }
  logf="$dir/.build/auto-renew.log"
  statef="$dir/.build/auto-renew.state"
  last_renew="$(sed -n 's/^lastRenewAt=//p' "$statef" 2>/dev/null | tail -1 || true)"
  now="$(date +%s)"

  # 1) 描述文件剩余天数
  days="$(profile_days_left "$bid")"
  if [ -z "$days" ]; then
    alert_once "${label}.noProfile" "$disp 签名异常" "找不到 ${bid} 的描述文件，App 可能装不上/打不开"
  else
    if awk -v d="$days" -v t="$DAYS_ALERT_THRESHOLD" 'BEGIN{exit !(d<=t)}'; then
      alert_once "${label}.expiring" "$disp 需要续签" "描述文件剩 ${days} 天（阈值 ${DAYS_ALERT_THRESHOLD}），请确认手机可达且 App 未在运行"
    fi
  fi

  # 2) 续签日志里最近的异常（忽略"上次成功续签之前"的旧报错）
  if [ -f "$logf" ]; then
    local cutoff; cutoff="$(date -v-"${ERR_LOOKBACK_HOURS}"H '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo '')"
    local recent ts ts_epoch fresh
    recent="$(grep '^\[.*\] !!' "$logf" 2>/dev/null | tail -1 || true)"
    if [ -n "$recent" ]; then
      ts="$(printf '%s' "$recent" | sed -n 's/^\[\([^]]*\)\].*/\1/p')"
      ts_epoch="$(date -j -f "%Y-%m-%d %H:%M:%S" "$ts" '+%s' 2>/dev/null || echo 0)"
      fresh=1
      [ -n "$cutoff" ] && [ -n "$ts" ] && [[ "$ts" > "$cutoff" ]] || fresh=0
      # 若之后已经成功续签过，则这条旧报错不再算问题
      if [ -n "$last_renew" ] && [ "$ts_epoch" -le "$last_renew" ]; then fresh=0; fi
      if [ "$fresh" -eq 1 ]; then
        alert_once "${label}.err" "$disp 续签脚本报错" "$(printf '%s' "$recent" | cut -c1-90)"
      fi
    fi
  else
    alert_once "${label}.noLog" "$disp 续签异常" "找不到续签日志 ${logf}，任务可能没在跑"
  fi

  # 3) 多久没成功续签
  if [ -n "$last_renew" ]; then
    stale_after="$(awk -v s="$RENEW_STALE_DAYS" 'BEGIN{printf "%.0f", s*86400}')"
    if [ $((now - last_renew)) -gt "$stale_after" ]; then
      alert_once "${label}.stale" "$disp 续签停滞" "已有 $(awk -v a="$last_renew" -v b="$now" 'BEGIN{printf "%.1f",(b-a)/86400}') 天没成功续签，请检查"
    fi
  fi

  # 4) launchd 任务在不在
  if ! launchctl list 2>/dev/null | grep -q "$label"; then
    alert_once "${label}.jobMissing" "$disp 续签任务没了" "launchd 任务 $label 未加载，请重跑 install-autorenew.sh"
  fi

  log "$disp: 剩余=${days:-未知}天  log=$([ -f "$logf" ] && echo 有 || echo 无)"
  return 0
}

log "===== watchdog 开始（${MODE}）====="
# 受监控的 App：label|项目目录|bundle id|显示名
check_app "cn.zxlumen.opencodepocket.autorenew" "$POCKET_IOS"            "cn.zxlumen.opencodepocket" "口袋opencode"
check_app "com.liuzixiang.yijing64.autorenew"   "$PROJECTS_ROOT/yijing64" "com.liuzixiang.Yijing64"   "易经64"
log "===== watchdog 结束 ====="
exit 0
