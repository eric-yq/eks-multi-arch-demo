#!/usr/bin/env bash
# 步骤 3a（方式 B：分别原生构建）：在"当前这台机器"上原生构建单架构镜像并推送。
#
#   在 x86 实例（如 c6a.xlarge）上执行  → 推送 <repo>:<tag>-amd64
#   在 Graviton 实例（如 c6g.xlarge）上执行 → 推送 <repo>:<tag>-arm64
#
# 两台机器都跑完后，在任意一台执行 ./scripts/03b-create-manifest-list.sh
# 把两个单架构 tag 合并成一个多架构 tag（manifest list）。
#
# 原生构建不需要 QEMU，也不需要 buildx：只用 docker build + docker push。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need docker
resolve_image_uri

# 默认取宿主机架构；确有需要时可用 TARGET_ARCH=amd64|arm64 覆盖（此时可能触发模拟执行）
ARCH="${TARGET_ARCH:-$(host_arch)}"
case "${ARCH}" in
  amd64) ARCH_TAG="${IMAGE_URI_AMD64}" ;;
  arm64) ARCH_TAG="${IMAGE_URI_ARM64}" ;;
  *) die "TARGET_ARCH 只支持 amd64 或 arm64，当前：${ARCH}" ;;
esac

JAR_PATH="${APP_DIR}/target/${JAR_NAME}"
if [[ ! -f "${JAR_PATH}" ]]; then
  die "未找到 jar：${JAR_PATH}
jar 与 CPU 架构无关，二选一：
  1) 在本机执行 ./scripts/02-build-jar.sh
  2) 从另一台机器拷贝：scp <other-host>:${JAR_PATH} ${JAR_PATH}"
fi

ensure_ecr_repo
ecr_login

build_args=(
  --build-arg "APP_VERSION=${IMAGE_TAG}"
  --build-arg "JAR_FILE=target/${JAR_NAME}"
  --build-arg "TARGETPLATFORM=linux/${ARCH}"
  --build-arg "TARGETARCH=${ARCH}"
)

if [[ "${ARCH}" != "$(host_arch)" ]]; then
  warn "TARGET_ARCH=${ARCH} 与宿主机架构 $(host_arch) 不一致：这已不是原生构建，"
  warn "会走 --platform 交叉构建（本 Dockerfile 无 RUN，因此仍不需要 QEMU）"
  build_args+=(--platform "linux/${ARCH}")
fi

log "宿主机架构：$(uname -m)    目标架构：${ARCH}"
log "构建镜像：${ARCH_TAG}"
docker build "${build_args[@]}" -t "${ARCH_TAG}" "${APP_DIR}"

log "推送镜像：${ARCH_TAG}"
docker push "${ARCH_TAG}"

log "校验镜像内的架构"
docker image inspect "${ARCH_TAG}" --format '   {{.Os}}/{{.Architecture}}   ({{.Id}})'

cat <<EOF

已完成本机（${ARCH}）的原生构建与推送：${ARCH_TAG}

下一步：
  - 到另一种架构的实例上执行同一个脚本（./scripts/02-build-jar.sh && ./scripts/03a-build-push-native.sh）
  - 两个架构都推送完成后，执行 ./scripts/03b-create-manifest-list.sh 合并成 ${IMAGE_URI}
EOF
