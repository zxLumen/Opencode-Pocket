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
FROM ghcr.io/anomalyco/opencode:1.19.0

# 官方镜像默认 root 且无 HOME;这里把 HOME 指到专用家目录(compose 挂可写卷)
ENV HOME=/home/opencode \
    # 禁止 opencode 自更新写自身(镜像内版本不可变)
    OPENCODE_DISABLE_AUTOUPDATE=1

# 辅助服务(static-server.mjs:工作台页 + /config 净化 + /workspace 只读预览)需要一个
# JS 运行时;官方镜像是 Alpine,自带的运行时里没有 node(只有 busybox),这里补上。
# 辅助服务只在容器内网 47311 监听,由边缘 Caddy 转发,不对外发布端口。
RUN apk add --no-cache nodejs

# 预建目录(镜像根文件系统只读后,只有被挂载的路径能写)
RUN mkdir -p /srv/config-ro \
             /home/opencode/.config/opencode \
             /home/opencode/.local/share/opencode \
             /home/opencode/.local/state/opencode \
             /home/opencode/.cache \
             /workspace \
    && chown -R 10001:10001 /home/opencode /workspace

# 基准配置 + 启动入口(只读区)
COPY --chown=10001:10001 opencode.json /srv/config-ro/opencode.json
COPY --chown=10001:10001 seed/AGENTS.md /srv/config-ro/AGENTS.md
COPY --chown=10001:10001 seed/README.md /srv/config-ro/README.md
COPY --chown=10001:10001 entrypoint.sh /usr/local/bin/opencode-play-entrypoint
COPY --chown=10001:10001 static-server.mjs /srv/static-server.mjs
COPY --chown=10001:10001 hub.html /srv/hub.html
RUN chmod +x /usr/local/bin/opencode-play-entrypoint

USER 10001:10001
WORKDIR /workspace

EXPOSE 4096 47311

ENTRYPOINT ["/usr/local/bin/opencode-play-entrypoint"]
# entrypoint exec opencode "$@" → opencode web --hostname 0.0.0.0 --port 4096
CMD ["web", "--hostname", "0.0.0.0", "--port", "4096"]
