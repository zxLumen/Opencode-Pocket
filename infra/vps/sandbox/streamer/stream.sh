#!/bin/sh
# 沙盒无头推流:Xvfb → Chromium(kiosk)→ ffmpeg 抓屏 → RTMP(YouTube)。
# 全部通过环境变量配置;缺 STREAM_KEY 时直接退出(不做无意义的 crash-loop)。
set -eu

STREAM_URL="${STREAM_URL:-http://sandbox-caddy/}"
STREAM_KEY="${STREAM_KEY:-}"
STREAM_RTMP="${STREAM_RTMP:-rtmp://a.rtmp.youtube.com/live2}"
WIDTH="${WIDTH:-1280}"
HEIGHT="${HEIGHT:-720}"
FPS="${FPS:-15}"
BITRATE="${BITRATE:-2500k}"
BUFSIZE="${BUFSIZE:-5000k}"
PRESET="${PRESET:-veryfast}"
START_DELAY="${START_DELAY:-8}"
DISPLAY_NUM="${DISPLAY_NUM:-99}"

export DISPLAY=":${DISPLAY_NUM}"

log() { echo "[streamer] $*" >&2; }

if [ -z "${STREAM_KEY}" ]; then
  log "未设置 STREAM_KEY(YouTube 推流密钥):不推流,退出。"
  log "请在服务器 .env 写入 YT_STREAM_KEY=... 后再启动本容器。"
  exit 1
fi

log "启动虚拟屏幕 ${WIDTH}x${HEIGHT}x24(DISPLAY=${DISPLAY})"
Xvfb "${DISPLAY}" -screen 0 "${WIDTH}x${HEIGHT}x24" -nolisten tcp -ac >/tmp/xvfb.log 2>&1 &
sleep 1

log "Chromium 全屏打开 ${STREAM_URL}"
chromium \
  --no-sandbox --disable-gpu --disable-dev-shm-usage \
  --no-first-run --no-default-browser-check --disable-session-crashed-bubble \
  --disable-background-timer-throttling --disable-backgrounding-occluded-windows \
  --disable-renderer-backgrounding --hide-scrollbars \
  --disable-features=CalculateNativeWinOcclusion,Translate,MediaRouter \
  --autoplay-policy=no-user-gesture-required \
  --force-device-scale-factor=1 \
  --kiosk --start-fullscreen \
  --window-size="${WIDTH},${HEIGHT}" --window-position=0,0 \
  --user-data-dir=/tmp/chromium-profile \
  "${STREAM_URL}" >/tmp/chromium.log 2>&1 &

log "等待页面加载 ${START_DELAY}s"
sleep "${START_DELAY}"

log "开始推流 → ${STREAM_RTMP}/(key 已隐藏)"
exec ffmpeg -hide_banner -loglevel warning -nostdin \
  -f x11grab -draw_mouse 0 -video_size "${WIDTH}x${HEIGHT}" -framerate "${FPS}" -i "${DISPLAY}.0" \
  -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 \
  -c:v libx264 -preset "${PRESET}" -tune zerolatency -pix_fmt yuv420p \
  -b:v "${BITRATE}" -maxrate "${BITRATE}" -bufsize "${BUFSIZE}" \
  -g $((FPS * 2)) -keyint_min $((FPS * 2)) -sc_threshold 0 \
  -c:a aac -b:a 128k -ar 44100 \
  -f flv "${STREAM_RTMP}/${STREAM_KEY}"
