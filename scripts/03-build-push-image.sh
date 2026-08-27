#!/usr/bin/env bash
# 步骤 3：把 jar 打成一个多架构镜像（linux/amd64 + linux/arm64）并推送到 ECR
#
# 产物是一个 manifest list（OCI image index）：同一个 tag 下同时包含两种架构的镜像，
# 节点拉取时由 containerd 按自身架构自动选择正确的那一份。
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

# ---------- ECR 仓库 ----------
if ! aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  log "创建 ECR 仓库：${ECR_REPO}"
  aws ecr create-repository \
    --repository-name "${ECR_REPO}" \
    --region "${AWS_REGION}" \
    --image-scanning-configuration scanOnPush=true >/dev/null
else
  log "ECR 仓库已存在：${ECR_REPO}"
fi

log "登录 ECR：${ECR_REGISTRY}"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

# ---------- 构建并推送 ----------
# 本 Dockerfile 只有 FROM/COPY/ENV，没有需要目标架构执行的 RUN，
# 因此在 x86 机器上交叉构建 arm64 镜像不需要 QEMU。
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
log "下一步：./scripts/04-deploy.sh"
