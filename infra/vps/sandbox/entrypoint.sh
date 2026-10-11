#!/bin/sh
# 启动入口:每次把「镜像内只读基准配置」重新烤回家目录。
# 家目录挂的是可写卷——opencode 会在 .config 里写 .gitignore 等,故不能整体只读;
# 这里保证:任何运行时对 opencode.json 的篡改,重启即被覆盖回出厂值。
set -e
mkdir -p "$HOME/.config/opencode"
cp /srv/config-ro/opencode.json "$HOME/.config/opencode/opencode.json"
# 全局助手说明(opencode 会读 $HOME/.config/opencode/AGENTS.md);同样每次覆盖回出厂值。
cp /srv/config-ro/AGENTS.md "$HOME/.config/opencode/AGENTS.md"
# 额外把助手说明播种到工作区(项目级 AGENTS.md,双保险);两个种子都仅当缺失时写,
# 不覆盖访客内容。/workspace 挂的是可写卷。
[ -f /workspace/README.md ] || cp /srv/config-ro/README.md /workspace/README.md 2>/dev/null || true
[ -f /workspace/AGENTS.md ] || cp /srv/config-ro/AGENTS.md /workspace/AGENTS.md 2>/dev/null || true
exec opencode "$@"
