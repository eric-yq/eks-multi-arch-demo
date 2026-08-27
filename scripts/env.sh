#!/usr/bin/env bash
# 所有脚本共用的配置与工具函数。
# 每个变量都可以用环境变量覆盖，例如：
#   AWS_REGION=ap-southeast-1 IMAGE_TAG=1.0.1 ./scripts/03-build-push-image.sh

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export CLUSTER_NAME="${CLUSTER_NAME:-multi-arch-demo}"
export NAMESPACE="${NAMESPACE:-demo}"
export ECR_REPO="${ECR_REPO:-java-arch-demo}"
export IMAGE_TAG="${IMAGE_TAG:-1.0.0}"
export PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
export BUILDER_NAME="${BUILDER_NAME:-multiarch-builder}"
export JAR_NAME="${JAR_NAME:-java-arch-demo.jar}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export APP_DIR="${REPO_ROOT}/app"
export K8S_DIR="${REPO_ROOT}/k8s"
export BUILD_DIR="${REPO_ROOT}/.build"

log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[error]\033[0m %s\n' "$*" >&2; exit 1; }

need() { command -v "$1" >/dev/null 2>&1 || die "缺少命令：$1，请先安装"; }

# 宿主机 CPU 架构 → 容器/Kubernetes 使用的架构名
host_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    *) die "不支持的架构：$(uname -m)" ;;
  esac
}

# 解析镜像地址。默认使用 ECR（需要 AWS 凭证）；
# 也可以直接 export IMAGE_URI=<registry>/<repo>:<tag> 指定任意 registry。
resolve_image_uri() {
  if [[ -n "${IMAGE_URI:-}" ]]; then
    export IMAGE_REPO_URI="${IMAGE_URI%:*}"
  else
    need aws
    AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
    [[ -n "${AWS_ACCOUNT_ID}" && "${AWS_ACCOUNT_ID}" != "None" ]] || die "无法获取 AWS 账号 ID，请检查 AWS 凭证"
    export AWS_ACCOUNT_ID
    export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    export IMAGE_REPO_URI="${ECR_REGISTRY}/${ECR_REPO}"
    export IMAGE_URI="${IMAGE_REPO_URI}:${IMAGE_TAG}"
  fi
  export REGISTRY_HOST="${IMAGE_URI%%/*}"
  export ECR_REGISTRY="${ECR_REGISTRY:-${REGISTRY_HOST}}"
  # 单架构 tag：<repo>:<tag>-amd64 / <repo>:<tag>-arm64
  export IMAGE_URI_AMD64="${IMAGE_REPO_URI}:${IMAGE_TAG}-amd64"
  export IMAGE_URI_ARM64="${IMAGE_REPO_URI}:${IMAGE_TAG}-arm64"
}

is_ecr_registry() { [[ "${REGISTRY_HOST:-}" == *.amazonaws.com ]]; }

# 幂等创建 ECR 仓库
ensure_ecr_repo() {
  is_ecr_registry || { log "非 ECR registry（${REGISTRY_HOST}），跳过仓库创建"; return 0; }
  need aws
  if aws ecr describe-repositories --repository-names "${ECR_REPO}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    log "ECR 仓库已存在：${ECR_REPO}"
  else
    log "创建 ECR 仓库：${ECR_REPO}"
    aws ecr create-repository \
      --repository-name "${ECR_REPO}" \
      --region "${AWS_REGION}" \
      --image-scanning-configuration scanOnPush=true >/dev/null
  fi
}

ecr_login() {
  is_ecr_registry || { log "非 ECR registry（${REGISTRY_HOST}），跳过登录"; return 0; }
  need aws
  log "登录 ECR：${REGISTRY_HOST}"
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${REGISTRY_HOST}"
}

# 找到一个 >= 21 的 JDK（Spring Boot 3.5 + Java 21）
find_jdk21() {
  local candidate
  if [[ -n "${JAVA_HOME:-}" && -x "${JAVA_HOME}/bin/javac" ]] \
      && "${JAVA_HOME}/bin/java" -version 2>&1 | grep -qE '"(2[1-9]|[3-9][0-9])'; then
    echo "${JAVA_HOME}"; return 0
  fi
  for candidate in /usr/lib/jvm/java-2[1-9]-* /usr/lib/jvm/jdk-2[1-9]* \
                   /usr/lib/jvm/temurin-2[1-9]* /opt/java/openjdk \
                   /Library/Java/JavaVirtualMachines/*/Contents/Home; do
    [[ -x "${candidate}/bin/javac" ]] || continue
    if "${candidate}/bin/java" -version 2>&1 | grep -qE '"(2[1-9]|[3-9][0-9])'; then
      echo "${candidate}"; return 0
    fi
  done
  return 1
}
