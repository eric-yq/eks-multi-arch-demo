#!/usr/bin/env bash
# 步骤 3（方式 A：单机交叉构建）：在一台机器上把 jar 打成多架构镜像并推送到 ECR
#
# 产物是一个 manifest list（OCI image index）：同一个 tag 下同时包含两种架构的镜像，
# 节点拉取时由 containerd 按自身架构自动选择正确的那一份。
#
# 如果你想在 x86 与 Graviton 实例上分别"原生"构建，请改用方式 B：
#   两台机器各自执行 ./scripts/03a-build-push-native.sh
#   任意一台再执行     ./scripts/03b-create-manifest-list.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need docker; need aws
resolve_image_uri

JAR_PATH="${APP_DIR}/target/${JAR_NAME}"
[[ -f "${JAR_PATH}" ]] || die "未找到 jar，请先执行 ./scripts/02-build-jar.sh"

# ---------- buildx ----------
if ! docker buildx version >/dev/null 2>&1; then
  die "未安装 docker buildx 插件。安装方式：
  mkdir -p ~/.docker/cli-plugins
  curl -sSL -o ~/.docker/cli-plugins/docker-buildx \\
    https://github.com/docker/buildx/releases/download/v0.36.1/buildx-v0.36.1.linux-amd64
  chmod +x ~/.docker/cli-plugins/docker-buildx"
fi

if ! docker buildx inspect "${BUILDER_NAME}" >/dev/null 2>&1; then
  log "创建 buildx builder：${BUILDER_NAME}（docker-container 驱动，支持多架构）"
  docker buildx create --name "${BUILDER_NAME}" --driver docker-container --bootstrap >/dev/null
fi

# ---------- QEMU 检查 ----------
# app/Dockerfile 里有 native-builder 阶段要编译 JNI 的 .so，这个 RUN 必须在目标架构下执行。
# 跨架构构建时依赖宿主机注册的 binfmt handler（QEMU），否则该阶段会失败。
host="$(host_arch)"
for platform in ${PLATFORMS//,/ }; do
  target_arch="${platform##*/}"
  [[ "${target_arch}" == "${host}" ]] && continue
  qemu_handler="qemu-aarch64"
  [[ "${target_arch}" == "amd64" ]] && qemu_handler="qemu-x86_64"
  if [[ ! -e "/proc/sys/fs/binfmt_misc/${qemu_handler}" ]]; then
    warn "要构建 ${platform}，但宿主机没有注册 ${qemu_handler}。"
    warn "本镜像含 JNI 原生库，native-builder 阶段需要在目标架构下执行，缺少 QEMU 会失败。"
    warn "二选一："
    warn "  1) 注册 QEMU：docker run --privileged --rm tonistiigi/binfmt --install ${target_arch}"
    warn "  2) 改用各架构原生构建（更快，推荐）："
    warn "     在 x86 与 Graviton 实例上分别跑 ./scripts/03a-build-push-native.sh，"
    warn "     再执行 ./scripts/03b-create-manifest-list.sh 合并"
    die "缺少 ${qemu_handler}，已中止"
  fi
  log "已检测到 ${qemu_handler}，可跨架构构建 ${platform}"
done

# ---------- ECR 仓库与登录 ----------
ensure_ecr_repo
ecr_login

# ---------- 构建并推送 ----------
# 注意：镜像里含 JNI 原生库（libarchdemo_native.so），native-builder 阶段的 RUN
# 必须在目标架构下执行，跨架构时走 QEMU 模拟（上面已检查）。
# 想完全避开模拟，请改用 03a + 03b 的各架构原生构建路径。
log "构建并推送多架构镜像：${IMAGE_URI}    平台：${PLATFORMS}"
docker buildx build \
  --builder "${BUILDER_NAME}" \
  --platform "${PLATFORMS}" \
  --provenance=false \
  --build-arg "APP_VERSION=${IMAGE_TAG}" \
  --build-arg "JAR_FILE=target/${JAR_NAME}" \
  -t "${IMAGE_URI}" \
  --push \
  "${APP_DIR}"

log "校验 manifest list（应同时出现 linux/amd64 与 linux/arm64）"
docker buildx imagetools inspect "${IMAGE_URI}"

log "镜像地址：${IMAGE_URI}"
log "下一步：./scripts/04a-deploy-java-amd64.sh"
