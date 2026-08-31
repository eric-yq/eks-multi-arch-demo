#!/usr/bin/env bash
# 步骤 7b：把两个单架构的多语言镜像 tag 合并成一个多架构 tag。
#
#   <repo>:<tag>-amd64  +  <repo>:<tag>-arm64   →   <repo>:<tag>（manifest list）
#
# 合并只操作 registry 里的 manifest，不重新构建、不上传镜像层，几秒钟完成。
# 在任意一台机器（x86 或 Graviton）上执行都可以。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need docker
resolve_polyglot_image_uri
ecr_login

log "检查两个单架构 tag 是否都已推送"
if ! create_manifest_list "${POLYGLOT_IMAGE_URI}" \
      "${POLYGLOT_IMAGE_URI_AMD64}" "${POLYGLOT_IMAGE_URI_ARM64}"; then
  die "缺少单架构镜像，请先在对应架构的实例上执行 ./scripts/07a-build-push-polyglot-native.sh"
fi

log "多语言镜像地址：${POLYGLOT_IMAGE_URI}"
log "下一步：./scripts/08-deploy-polyglot.sh"
