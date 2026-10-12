#!/usr/bin/env bash
# 构建「沙盒裁剪版」opencode Web UI。
#
# 目的:沙盒只需要「单一会话 + Plan/Build + 会话可调用的 agent」,其余
# (标题栏/标签/会话管理/设置/命令面板/终端/git/更改面板…) 全部去掉。
# 做法:拉取 opencode 源码(锁定 commit) → 打我们的 patch(app-fork.patch) →
# 构建 packages/app → 产物 dist。
#
# sourcemap 策略(方案 B:不进公开镜像,但留档):
#   构建会产出 sourcemap(vite sourcemap:true,约 59MB)。为保证:
#     ① 公开镜像/线上不暴露源码(.map 不随镜像发布,也顺手去掉 JS/CSS 末尾的
#        sourceMappingURL 注释,避免 DevTools 404 报警);
#     ② 出事时仍能按「同一 pin 的产物」还原源码 —— 把 .map 原样分离到 MAPS_OUT,
#        由 CI 作为 artifact 留档(GitHub Actions → 该次构建的 artifact)。
#   也就是说:dist 永远不含 .map;.map 在 MAPS_OUT 里,按需取用。
#
# 产物:
#   $WORK/packages/app/dist   —— 干净静态资源(不含 .map),由镜像 COPY 到 /srv/app-dist
#   $MAPS_OUT                 —— 对应的 .map 文件(默认 <WORK 的上级>/app-maps),留档用
set -euo pipefail

OPENCODE_REPO="${OPENCODE_REPO:-https://github.com/anomalyco/opencode.git}"
# 锁定到 v2.0.27 tag 的 commit —— 必须与运行镜像 ghcr.io/anomalyco/opencode:2.0.27
# 完全同版本(UI 路由/接口/鉴权都要对齐)。升级 opencode 时改这里 + Dockerfile 的
# 基础镜像 tag + 重做 patch。
OPENCODE_COMMIT="${OPENCODE_COMMIT:-1f4d07a4a519185955ae8ab2ea3607805509e386}"

HERE="$(cd "$(dirname "$0")" && pwd)"
WORK="${1:-/build/opencode}"
PATCH="${HERE}/app-fork.patch"
# sourcemap 留档目录(默认与 WORK 同级:WORK=/build/opencode → MAPS_OUT=/build/app-maps)。
MAPS_OUT="${MAPS_OUT:-$(dirname "${WORK}")/app-maps}"

echo "==> 拉取 opencode @ ${OPENCODE_COMMIT}"
rm -rf "${WORK}"
git clone --filter=blob:none --no-checkout "${OPENCODE_REPO}" "${WORK}"
git -C "${WORK}" checkout "${OPENCODE_COMMIT}"

echo "==> 应用 patch"
git -C "${WORK}" apply "${PATCH}"

echo "==> bun install"
(cd "${WORK}" && bun install)

echo "==> 构建 packages/app(prod channel:图标/资源前缀与官方镜像一致)"
(cd "${WORK}" && OPENCODE_CHANNEL=prod bun run --cwd packages/app build)

DIST="${WORK}/packages/app/dist"

echo "==> 分离 sourcemap(不进镜像;留档到 ${MAPS_OUT})"
rm -rf "${MAPS_OUT}"
mkdir -p "${MAPS_OUT}"
# 把 dist 下所有 .map 按相对路径搬到 MAPS_OUT(保持目录结构,便于对应查找)。
( cd "${DIST}" && find . -type f -name '*.map' -print0 ) | while IFS= read -r -d '' rel; do
  rel="${rel#./}"
  mkdir -p "${MAPS_OUT}/$(dirname "${rel}")"
  mv "${DIST}/${rel}" "${MAPS_OUT}/${rel}"
done
# 去掉 JS/CSS 末尾的 sourceMappingURL 注释(否则 DevTools 会尝试拉取已不存在的 .map)。
find "${DIST}" -type f \( -name '*.js' -o -name '*.mjs' -o -name '*.cjs' -o -name '*.css' \) \
  -exec sed -i '/sourceMappingURL=/d' {} +

echo "==> 产物 dist:        $(du -sh "${DIST}" | cut -f1)  (${DIST})"
echo "==> sourcemap 留档:   $(du -sh "${MAPS_OUT}" | cut -f1)  (${MAPS_OUT})"
