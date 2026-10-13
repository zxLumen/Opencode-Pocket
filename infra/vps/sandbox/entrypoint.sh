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
[ -f /workspace/AGENTS.md ] || cp /srv/config-ro/AGENTS.md /workspace/AGENTS.md 2>/dev/null || true
# 与 TUI 一致的搜索:opencode 的 websearch 能力由 `opencode`(Zen) 集成**自带的搜索连接**
# 提供(exa/firecrawl/parallel/tavily/tinyfish,见二进制里的 opencode.websearch.*),
# **与模型走哪个 provider 无关**。所以把 Zen 凭据导入沙盒即可;兼容旧的 opencode-go 变量。
# 注意:opencode v2 的凭据存在 DB 里,写 auth.json **不生效** —— 必须用 `auth import`。
if [ -n "${SANDBOX_OPENCODE_ZEN_KEY:-}" ] || [ -n "${SANDBOX_OPENCODE_GO_KEY:-}" ]; then
  {
    printf '['
    sep=''
    if [ -n "${SANDBOX_OPENCODE_ZEN_KEY:-}" ]; then
      printf '%s{"id":"cred-opencode","integrationID":"opencode","label":"OpenCode Zen","active":true,"value":{"type":"key","key":"%s"}}' \
        "$sep" "$SANDBOX_OPENCODE_ZEN_KEY"
      sep=','
    fi
    if [ -n "${SANDBOX_OPENCODE_GO_KEY:-}" ]; then
      printf '%s{"id":"cred-opencode-go","integrationID":"opencode-go","label":"OpenCode Go","active":true,"value":{"type":"key","key":"%s"}}' \
        "$sep" "$SANDBOX_OPENCODE_GO_KEY"
    fi
    printf ']'
  } | opencode auth import --standalone >/dev/null 2>&1 \
      || echo "[sandbox-helper] 凭据导入失败(搜索将不可用,但不影响启动)" >&2
fi
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
