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

# 解析 AWS 账号并拼出 ECR 镜像地址（需要有效的 AWS 凭证）
resolve_image_uri() {
  need aws
  AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
  [[ -n "${AWS_ACCOUNT_ID}" && "${AWS_ACCOUNT_ID}" != "None" ]] || die "无法获取 AWS 账号 ID，请检查 AWS 凭证"
  export AWS_ACCOUNT_ID
  export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  export IMAGE_URI="${IMAGE_URI:-${ECR_REGISTRY}/${ECR_REPO}:${IMAGE_TAG}}"
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
