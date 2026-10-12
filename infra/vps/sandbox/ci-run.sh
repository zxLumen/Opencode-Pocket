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
    "${SUBDIR}/Caddyfile" "${SUBDIR}/docker-compose.yml" "${SUBDIR}/deploy.sh" "${SUBDIR}/ci-run.sh" "${SUBDIR}/auto-deploy.sh"
  cp "${TMP}/${SUBDIR}/Caddyfile"          ./Caddyfile
  cp "${TMP}/${SUBDIR}/docker-compose.yml" ./docker-compose.yml
  cp "${TMP}/${SUBDIR}/deploy.sh"          ./deploy.sh && chmod +x ./deploy.sh
  # 本脚本自身 + auto-deploy.sh:先落临时名再 mv 原子替换(避免边跑边被改坏)
  cp "${TMP}/${SUBDIR}/ci-run.sh" ./ci-run.sh.new && chmod +x ./ci-run.sh.new
  mv -f ./ci-run.sh.new ./ci-run.sh
  cp "${TMP}/${SUBDIR}/auto-deploy.sh" ./auto-deploy.sh.new && chmod +x ./auto-deploy.sh.new
  mv -f ./auto-deploy.sh.new ./auto-deploy.sh
  echo "==> 配置已更新"
fi

# 自愈：博客站点的 Caddyfile 由 zxLumen-Blog 仓库同步，可能把 /pocketd 路由覆盖掉
# (App 传图依赖它；丢了会 POST /pocketd/upload 落到 opencode 返回 405)。
# 幂等：缺了才补，补完 reload；不依赖博客仓库那次部署是否记得带上。
ensure_pocketd_route() {
  local F="/home/ubuntu/zxLumen-Blog/docker/Caddyfile"
  [ -f "${F}" ] || return 0
  grep -q 'handle /pocketd/\*' "${F}" && return 0
  echo "==> 补 /pocketd 路由:${F}"
  python3 - "${F}" <<'PY' || true
import sys
F = sys.argv[1]
s = open(F, encoding='utf-8').read()
old = """	reverse_proxy host.docker.internal:4096 {
		# SSE(/api/event)必须关闭缓冲
		flush_interval -1
	}
"""
new = """	# App 图片上传中继：/pocketd/upload -> pocketd(8788)/upload
	handle /pocketd/* {
		uri strip_prefix /pocketd
		reverse_proxy host.docker.internal:8788
	}
	handle {
		reverse_proxy host.docker.internal:4096 {
			# SSE(/api/event)必须关闭缓冲
			flush_interval -1
		}
	}
"""
if s.count(old) == 1:
    open(F, "w", encoding="utf-8").write(s.replace(old, new))
    print("patched")
else:
    print(f"skip: anchor count={s.count(old)}")
PY
  if docker exec docker-caddy-1 caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    docker exec docker-caddy-1 caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true
    echo "==> 已补丁并 reload"
  fi
}
ensure_pocketd_route || true

./deploy.sh "${IMAGE_TAG}"

# deploy 之后再确保一次（避免本次部署过程中被覆盖）
ensure_pocketd_route || true
