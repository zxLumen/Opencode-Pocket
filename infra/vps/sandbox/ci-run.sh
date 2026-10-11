#!/usr/bin/env bash
# 部署入口(在服务器 ~/Opencode-Pocket/sandbox 内运行):
#   1) 从公开仓库稀疏拉取「服务器侧配置」(Caddyfile / docker-compose.yml / deploy.sh / 本脚本)
#      —— 服务器这台机器从不 `git pull`;
#   2) 交给 deploy.sh 拉镜像 + 起栈。
#
# 触发方式二选一:
#   - GitHub Actions 通过 authorized_keys 的 command= 调用(SSH_ORIGINAL_COMMAND = git sha);
#   - 服务器 cron 跑 ./auto-deploy.sh 轮询本仓库 main 的 SHA(当前采用,见 docs/vps-sandbox.md)。
set -euo pipefail
cd "$(dirname "$0")"

IMAGE_TAG="${SSH_ORIGINAL_COMMAND:-latest}"
REF="${IMAGE_TAG}"

REPO_URL="${REPO_URL:-https://github.com/zxLumen/Opencode-Pocket.git}"
SUBDIR="infra/vps/sandbox"

echo "==> 触发部署 IMAGE_TAG=${IMAGE_TAG}"

# 同步服务器侧配置(仅这几个文件;用 sparse 拉取避免整仓 clone 到服务器)
if [ "${IMAGE_TAG}" != "latest" ]; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "${TMP}"' EXIT
  echo "==> 同步配置:${REPO_URL} @ ${REF}"
  git -C "${TMP}" init -q
  git -C "${TMP}" remote add origin "${REPO_URL}"
  git -C "${TMP}" fetch -q --depth 1 origin "${REF}"
  git -C "${TMP}" checkout -q FETCH_HEAD -- \
    "${SUBDIR}/Caddyfile" "${SUBDIR}/docker-compose.yml" "${SUBDIR}/deploy.sh" "${SUBDIR}/ci-run.sh"
  cp "${TMP}/${SUBDIR}/Caddyfile"          ./Caddyfile
  cp "${TMP}/${SUBDIR}/docker-compose.yml" ./docker-compose.yml
  cp "${TMP}/${SUBDIR}/deploy.sh"          ./deploy.sh && chmod +x ./deploy.sh
  # 本脚本自身:先落到临时名再 mv 原子替换(避免边跑边被改坏)
  cp "${TMP}/${SUBDIR}/ci-run.sh" ./ci-run.sh.new && chmod +x ./ci-run.sh.new
  mv -f ./ci-run.sh.new ./ci-run.sh
  echo "==> 配置已更新"
fi

./deploy.sh "${IMAGE_TAG}"
