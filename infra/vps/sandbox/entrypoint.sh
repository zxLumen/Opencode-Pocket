#!/bin/sh
# 启动入口:每次把「镜像内只读基准配置」重新烤回家目录。
# 家目录挂的是可写卷——opencode 会在 .config 里写 .gitignore 等,故不能整体只读;
# 这里保证:任何运行时对 opencode.json 的篡改,重启即被覆盖回出厂值。
set -e
# opencode v2.0.x 强制 Basic 鉴权:容器内辅助服务直连 127.0.0.1:4096 需要自带凭据。
# 由同一个密码现算 "Basic <base64>"(边缘 Caddy 侧用同样的算法,见 docker-compose.yml)。
if [ -n "${OPENCODE_SERVER_PASSWORD:-}" ]; then
  SANDBOX_UPSTREAM_AUTH="Basic $(printf 'opencode:%s' "$OPENCODE_SERVER_PASSWORD" | base64 | tr -d '\n')"
  export SANDBOX_UPSTREAM_AUTH
fi
mkdir -p "$HOME/.config/opencode"
cp /srv/config-ro/opencode.json "$HOME/.config/opencode/opencode.json"
# 全局助手说明(opencode 会读 $HOME/.config/opencode/AGENTS.md);同样每次覆盖回出厂值。
cp /srv/config-ro/AGENTS.md "$HOME/.config/opencode/AGENTS.md"
# 额外把助手说明播种到工作区(项目级 AGENTS.md,双保险);两个种子都仅当缺失时写,
# 不覆盖访客内容。/workspace 挂的是可写卷。
[ -f /workspace/README.md ] || cp /srv/config-ro/README.md /workspace/README.md 2>/dev/null || true
# AGENTS.md 是我们自己的"助手说明"(非访客内容):每次强制刷新,避免工作区里留着旧版导致助手不知道新约定。
cp /srv/config-ro/AGENTS.md /workspace/AGENTS.md 2>/dev/null || true
# 联网搜索(websearch)是 opencode **自带的免费匿名能力**(见二进制里的 opencode.websearch.*:
# exa/firecrawl/parallel/tavily/tinyfish),请求由 opencode 侧转发,不需要任何账号凭据 ——
# 实测在「无任何集成」状态下依然可用。默认后端由 opencode.json 的 websearch.provider 指定。
# 因此这里**不导入任何凭据**(尤其不要把一个匿名可玩的容器和你的账号 key 绑在一起)。
# 辅助服务(内网 47311,由边缘 Caddy 转发):工作台页 + /config 净化 + /workspace 预览
# + 访客后端反代。用**监督循环常驻**——即便被误杀(如 agent 腾端口)也自动拉起,
# 避免整站 404。先起它再起 opencode:它取上游配置时自带重试,不怕 opencode 未就绪。
(
  set +e
  while true; do
    node /srv/static-server.mjs
    echo "[sandbox-helper] exited, restarting in 1s" >&2
    sleep 1
  done
) &
exec opencode "$@"
