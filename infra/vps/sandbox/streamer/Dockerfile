# 访客沙盒 · 无头推流容器(可选;默认不启动)
#
# 作用:把沙盒的「直播画面」自动推到 YouTube,全程无人值守 —— 无需你留一台电脑开 OBS。
#   ① Xvfb 起一块虚拟屏幕(固定分辨率)
#   ② Chromium 以 kiosk/全屏打开沙盒页面(默认 sandbox-caddy 的工作台)
#   ③ ffmpeg 抓屏(x11grab)→ H.264 → RTMP 推给 YouTube(附静音音轨:YouTube 要求有音轨)
#
# 启动(见 docs/vps-sandbox.md「无头推流」):
#   docker compose --profile stream up -d streamer
#
# 只需 STREAM_KEY(YouTube 推流密钥);分辨率/帧率/码率等均可用环境变量覆盖(见 stream.sh)。
FROM debian:bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

# chromium:无头浏览器;ffmpeg:抓屏 + 编码;xvfb:虚拟屏幕;
# fonts-noto-cjk:界面是中文,缺 CJK 字体全是方块;tini:正确转发信号给 ffmpeg。
RUN apt-get update && apt-get install -y --no-install-recommends \
      chromium \
      ffmpeg \
      xvfb \
      x11-utils \
      fonts-noto-cjk \
      fonts-noto-color-emoji \
      ca-certificates \
      tini \
    && rm -rf /var/lib/apt/lists/*

COPY stream.sh /usr/local/bin/stream.sh
RUN chmod +x /usr/local/bin/stream.sh

# 无参数;全部行为由环境变量驱动。
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/stream.sh"]
