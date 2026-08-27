#!/usr/bin/env bash
# 步骤 3b（方式 B：分别原生构建）：把两个单架构 tag 合并成一个多架构 tag。
#
#   <repo>:<tag>-amd64  +  <repo>:<tag>-arm64   →   <repo>:<tag>（manifest list）
#
# 合并只操作 registry 里的 manifest，不重新构建、不上传镜像层，几秒钟完成。
# 在任意一台机器（x86 或 Graviton）上执行都可以。
#
# 自建 HTTP registry 可用 INSECURE_REGISTRY=true 跳过 TLS。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need docker
resolve_image_uri
ecr_login

HAS_BUILDX=false
docker buildx version >/dev/null 2>&1 && HAS_BUILDX=true

manifest_args=()
[[ "${INSECURE_REGISTRY:-false}" == "true" ]] && manifest_args+=(--insecure)

manifest_exists() {
  if [[ "${HAS_BUILDX}" == "true" ]]; then
    docker buildx imagetools inspect "$1" >/dev/null 2>&1
  else
    docker manifest inspect "${manifest_args[@]}" "$1" >/dev/null 2>&1
  fi
}

log "检查两个单架构 tag 是否都已推送"
missing=0
for tag in "${IMAGE_URI_AMD64}" "${IMAGE_URI_ARM64}"; do
  if manifest_exists "${tag}"; then
    printf '   [ok]      %s\n' "${tag}"
  else
    printf '   [missing] %s\n' "${tag}"
    missing=1
  fi
done
[[ "${missing}" -eq 0 ]] || die "缺少单架构镜像，请先在对应架构的实例上执行 ./scripts/03a-build-push-native.sh"

log "合并为多架构 tag：${IMAGE_URI}"
if [[ "${HAS_BUILDX}" == "true" ]]; then
  docker buildx imagetools create -t "${IMAGE_URI}" "${IMAGE_URI_AMD64}" "${IMAGE_URI_ARM64}"
else
  # 没有 buildx 时用 docker manifest（等价效果）
  docker manifest rm "${IMAGE_URI}" >/dev/null 2>&1 || true
  docker manifest create "${manifest_args[@]}" "${IMAGE_URI}" \
    --amend "${IMAGE_URI_AMD64}" \
    --amend "${IMAGE_URI_ARM64}"
  docker manifest push "${manifest_args[@]}" "${IMAGE_URI}"
fi

log "校验 manifest list（应同时出现 linux/amd64 与 linux/arm64）"
if [[ "${HAS_BUILDX}" == "true" ]]; then
  docker buildx imagetools inspect "${IMAGE_URI}"
else
  docker manifest inspect "${manifest_args[@]}" "${IMAGE_URI}" \
    | grep -E '"architecture"|"os"' \
    | sed 's/^[[:space:]]*/   /'
fi

log "镜像地址：${IMAGE_URI}"
log "下一步：./scripts/04-deploy.sh"
