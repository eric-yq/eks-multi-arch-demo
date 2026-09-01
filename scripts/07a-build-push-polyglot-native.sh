#!/usr/bin/env bash
# 步骤 7a：在**当前这台实例**上原生构建多语言镜像（Go / Python / C++）并推送。
#
#   在 x86 实例（c7i）上执行      → 推送 <repo>:<tag>-amd64
#   在 Graviton 实例（c9g）上执行 → 推送 <repo>:<tag>-arm64
#
# 为什么必须两台机器各跑一次：Go 与 C++ 会编译成原生机器码，没法像 jar / .py 那样
# 一份产物通吃两种架构。这里刻意用**原生编译**而不是交叉编译 / QEMU 模拟：
#   - 不需要 buildx 插件，普通 docker build 即可
#   - 不需要 QEMU，编译速度就是本机速度
#   - 编译期的架构优化（-march 之类）也能按实际硬件生效
#
# 两台都推完后，在任意一台执行 ./scripts/07b-create-polyglot-manifest.sh 合并。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need docker
resolve_polyglot_image_uri

ARCH="$(host_arch)"
case "${ARCH}" in
  amd64) ARCH_TAG="${POLYGLOT_IMAGE_URI_AMD64}" ;;
  arm64) ARCH_TAG="${POLYGLOT_IMAGE_URI_ARM64}" ;;
  *) die "不支持的架构：${ARCH}" ;;
esac

[[ -f "${POLYGLOT_DIR}/Dockerfile" ]] || die "找不到 ${POLYGLOT_DIR}/Dockerfile"

ensure_ecr_repo "${POLYGLOT_ECR_REPO}"
ecr_login

log "宿主机：$(uname -m)（${ARCH}）    原生构建镜像：${ARCH_TAG}"
log "构建内容：Go 服务（CGO_ENABLED=1）+ 自研 C 库 .so + C++ 压测二进制（含 SIMD）+ Python 脚本"

docker build \
  --build-arg "APP_VERSION=${POLYGLOT_IMAGE_TAG}" \
  --build-arg "BUILD_ARCH=${ARCH}" \
  -t "${ARCH_TAG}" \
  "${POLYGLOT_DIR}"

log "推送镜像：${ARCH_TAG}"
docker push "${ARCH_TAG}"

log "校验镜像内的架构与各语言运行时"
docker image inspect "${ARCH_TAG}" --format '   镜像架构: {{.Os}}/{{.Architecture}}'
docker run --rm --entrypoint sh "${ARCH_TAG}" -c '
  printf "   容器内 uname -m : %s\n" "$(uname -m)"
  printf "   C++ 运行时      : %s\n" "$(/app/bench-cpp --version)"
  printf "   C++ SIMD 路径   : %s\n" "$(/app/bench-cpp --simd-path)"
  printf "   Python 运行时   : %s\n" "$(python3 /app/bench.py --version)"
  printf "   CGO 原生库      : %s\n" "$(ls -l /app/lib/libgodemo_native.so | awk "{print \$5\" bytes\"}")"
' 2>/dev/null || warn "镜像内自检失败（不影响已推送的镜像）"

cat <<EOF

已完成本机（${ARCH}）的原生构建与推送：${ARCH_TAG}

下一步：
  - 到另一种架构的实例上执行同一个脚本（git clone 后直接 ./scripts/07a-build-push-polyglot-native.sh）
  - 两种架构都推送完成后，执行 ./scripts/07b-create-polyglot-manifest.sh 合并成
    ${POLYGLOT_IMAGE_URI}
EOF
