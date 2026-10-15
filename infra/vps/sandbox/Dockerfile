# 访客沙盒镜像:公开的 opencode web(code-sandbox.<DOMAIN>)。
#
# 隔离边界 = 容器(见本仓库 docs/vps-sandbox.md):
#   - 出厂即切非 root(官方镜像默认 root,对公网沙盒不可接受)
#   - 只挂 /workspace 与家目录,其它宿主路径一律不可见
#   - compose 侧再叠加 read_only 根文件系统 / cap_drop / no-new-privileges / 资源限额
#
# 配置策略:基准 opencode.json 烤进镜像只读区(/srv/config-ro),每次启动由 entrypoint
# 覆盖到家目录 —— 家目录必须可写(opencode 会在 .config 里写 .gitignore),但配置内容
# 以镜像为准,运行时改动重启即还原。见同目录 entrypoint.sh。
#
# Web UI 用「裁剪版」(见 app-fork/ + build-app.sh):只保留「单一会话 + Plan/Build +
# 会话可调用的 agent」,其余(标题栏/标签/会话管理/设置/命令面板/终端/git/更改…)全去掉。
# 构建阶段拉 opencode 源码(锁定 commit)+ 打 patch + 构建,产物 dist 拷进最终镜像,
# 由辅助服务(static-server.mjs)提供 —— opencode 只出 API。
#
# sourcemap(方案 B):构建产出的 .map 由 build-app.sh 分离到 /build/app-maps,运行镜像
# **不包含**它们(只 COPY dist);CI 用 `app-maps` 阶段把它们导出为 artifact 留档。

# ============ 构建阶段:裁剪版 Web UI ============
FROM oven/bun:1 AS app-build
RUN apt-get update \
    && apt-get install -y --no-install-recommends git ca-certificates \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY build-app.sh app-fork/ ./
RUN ./build-app.sh /build/opencode

# ============ sourcemap 留档阶段(方案 B;不进运行镜像)============
# 只含 build-app.sh 分离出来的 .map;CI 用
#   docker buildx build --target app-maps --output type=local,dest=./app-maps
# 把它导出到 runner 并作为 artifact 上传。运行阶段绝不引用本阶段。
FROM scratch AS app-maps
COPY --from=app-build /build/app-maps /

# ============ 运行阶段 ============
FROM ghcr.io/anomalyco/opencode:2.0.27

# 官方镜像默认 root 且无 HOME;这里把 HOME 指到专用家目录(compose 挂可写卷)
ENV HOME=/home/opencode \
    # 禁止 opencode 自更新写自身(镜像内版本不可变)
    OPENCODE_DISABLE_AUTOUPDATE=1

# 辅助服务(static-server.mjs:工作台页 + /config 净化 + /workspace 只读预览)需要一个
# JS 运行时;官方镜像是 Alpine,自带的运行时里没有 node(只有 busybox),这里补上。
# 辅助服务只在容器内网 47311 监听,由边缘 Caddy 转发,不对外发布端口。
# 给沙盒里的 agent 补齐常用工具:npm(装依赖)/curl/jq(取数·调试)/git
RUN apk add --no-cache nodejs npm curl jq git

# 预建目录(镜像根文件系统只读后,只有被挂载的路径能写)
RUN mkdir -p /srv/config-ro \
             /srv/app-dist \
             /home/opencode/.config/opencode \
             /home/opencode/.local/share/opencode \
             /home/opencode/.local/state/opencode \
             /home/opencode/.cache \
             /workspace \
    && chown -R 10001:10001 /home/opencode /workspace /srv/app-dist

# 基准配置 + 启动入口(只读区)
COPY --chown=10001:10001 opencode.json /srv/config-ro/opencode.json
COPY --chown=10001:10001 seed/AGENTS.md /srv/config-ro/AGENTS.md
COPY --chown=10001:10001 seed/README.md /srv/config-ro/README.md
COPY --chown=10001:10001 entrypoint.sh /usr/local/bin/opencode-play-entrypoint
COPY --chown=10001:10001 static-server.mjs /srv/static-server.mjs
COPY --chown=10001:10001 hub.html /srv/hub.html
COPY --chown=10001:10001 board.html /srv/board.html
COPY --chown=10001:10001 history.html /srv/history.html
COPY --chown=10001:10001 reviews.html /srv/reviews.html
# 裁剪版 Web UI(由构建阶段产出;辅助服务从 /srv/app-dist 提供)
COPY --from=app-build --chown=10001:10001 /build/opencode/packages/app/dist /srv/app-dist
RUN chmod +x /usr/local/bin/opencode-play-entrypoint

USER 10001:10001
WORKDIR /workspace

EXPOSE 4096 47311

ENTRYPOINT ["/usr/local/bin/opencode-play-entrypoint"]
# entrypoint exec opencode "$@" → opencode serve --hostname 0.0.0.0 --port 4096
# (v2.0.x 的子命令是 `serve`;v1.19 的 `web` 已移除)
CMD ["serve", "--hostname", "0.0.0.0", "--port", "4096"]
