#!/usr/bin/env bash
# 所有脚本共用的配置与工具函数。
# 每个变量都可以用环境变量覆盖，例如：
#   AWS_REGION=ap-southeast-1 IMAGE_TAG=1.0.1 ./scripts/03-build-push-image.sh

export AWS_REGION="${AWS_REGION:-us-east-1}"
export AWS_DEFAULT_REGION="${AWS_REGION}"
export CLUSTER_NAME="${CLUSTER_NAME:-multi-arch-demo}"
export NAMESPACE="${NAMESPACE:-demo}"
export ECR_REPO="${ECR_REPO:-java-arch-demo}"
export IMAGE_TAG="${IMAGE_TAG:-1.3.0}"
export PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
export BUILDER_NAME="${BUILDER_NAME:-multiarch-builder}"
export JAR_NAME="${JAR_NAME:-java-arch-demo.jar}"

# ---- 多语言（Go / Python / C++）服务，独立镜像与独立 ECR 仓库 ----
export POLYGLOT_ECR_REPO="${POLYGLOT_ECR_REPO:-polyglot-arch-demo}"
export POLYGLOT_IMAGE_TAG="${POLYGLOT_IMAGE_TAG:-1.1.0}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export REPO_ROOT
export APP_DIR="${REPO_ROOT}/app"
export POLYGLOT_DIR="${REPO_ROOT}/polyglot"
export K8S_DIR="${REPO_ROOT}/k8s"
export POLYGLOT_K8S_DIR="${REPO_ROOT}/k8s/polyglot"
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

# 在集群内跑一个一次性探针 Pod 并取回完整输出。
# 不用 `kubectl run --rm -i`：那种写法要 attach 容器，容器启动/退出与 attach 存在竞争，
# 会出现 "couldn't attach to pod ... falling back to streaming logs"，并可能丢掉开头几行输出。
# 这里改成：创建 Pod → 等它跑完 → kubectl logs 取输出 → 删除。
run_probe() {
  local name="$1" cmd="$2" phase=""
  local image="${PROBE_IMAGE:-public.ecr.aws/docker/library/alpine:3.22}"

  kubectl -n "${NAMESPACE}" delete pod "${name}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" run "${name}" --restart=Never --image="${image}" \
    --command -- sh -c "${cmd}" >/dev/null || { warn "探针 Pod ${name} 创建失败"; return 1; }

  for _ in $(seq 1 90); do
    phase="$(kubectl -n "${NAMESPACE}" get pod "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]] && break
    sleep 2
  done

  kubectl -n "${NAMESPACE}" logs "${name}" 2>/dev/null || warn "读取 ${name} 日志失败"
  kubectl -n "${NAMESPACE}" delete pod "${name}" --wait=false >/dev/null 2>&1 || true
  [[ "${phase}" == "Succeeded" ]] || warn "探针 Pod ${name} 未正常结束（phase=${phase:-unknown}）"
}

is_ecr_registry() { [[ "${REGISTRY_HOST:-}" == *.amazonaws.com ]]; }

# 解析多语言服务的镜像地址（与 Java 服务分开，不同 ECR 仓库）
resolve_polyglot_image_uri() {
  if [[ -n "${POLYGLOT_IMAGE_URI:-}" ]]; then
    export POLYGLOT_IMAGE_REPO_URI="${POLYGLOT_IMAGE_URI%:*}"
  else
    need aws
    AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
    [[ -n "${AWS_ACCOUNT_ID}" && "${AWS_ACCOUNT_ID}" != "None" ]] || die "无法获取 AWS 账号 ID，请检查 AWS 凭证"
    export AWS_ACCOUNT_ID
    export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    export POLYGLOT_IMAGE_REPO_URI="${ECR_REGISTRY}/${POLYGLOT_ECR_REPO}"
    export POLYGLOT_IMAGE_URI="${POLYGLOT_IMAGE_REPO_URI}:${POLYGLOT_IMAGE_TAG}"
  fi
  export REGISTRY_HOST="${POLYGLOT_IMAGE_URI%%/*}"
  export ECR_REGISTRY="${ECR_REGISTRY:-${REGISTRY_HOST}}"
  export POLYGLOT_IMAGE_URI_AMD64="${POLYGLOT_IMAGE_REPO_URI}:${POLYGLOT_IMAGE_TAG}-amd64"
  export POLYGLOT_IMAGE_URI_ARM64="${POLYGLOT_IMAGE_REPO_URI}:${POLYGLOT_IMAGE_TAG}-arm64"
}

# 幂等创建 ECR 仓库。用法：ensure_ecr_repo [仓库名]，默认 ${ECR_REPO}
ensure_ecr_repo() {
  local repo="${1:-${ECR_REPO}}"
  is_ecr_registry || { log "非 ECR registry（${REGISTRY_HOST}），跳过仓库创建"; return 0; }
  need aws
  if aws ecr describe-repositories --repository-names "${repo}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    log "ECR 仓库已存在：${repo}"
  else
    log "创建 ECR 仓库：${repo}"
    aws ecr create-repository \
      --repository-name "${repo}" \
      --region "${AWS_REGION}" \
      --image-scanning-configuration scanOnPush=true >/dev/null
  fi
}

# 把两个单架构 tag 合并成一个多架构 tag（manifest list）
# 用法：create_manifest_list <多架构tag> <amd64 tag> <arm64 tag>
create_manifest_list() {
  local target="$1" amd64_tag="$2" arm64_tag="$3"
  local manifest_args=()
  [[ "${INSECURE_REGISTRY:-false}" == "true" ]] && manifest_args+=(--insecure)

  local has_buildx=false
  docker buildx version >/dev/null 2>&1 && has_buildx=true

  local missing=0 tag
  for tag in "${amd64_tag}" "${arm64_tag}"; do
    if { [[ "${has_buildx}" == "true" ]] && docker buildx imagetools inspect "${tag}" >/dev/null 2>&1; } \
       || { [[ "${has_buildx}" != "true" ]] && docker manifest inspect "${manifest_args[@]}" "${tag}" >/dev/null 2>&1; }; then
      printf '   [ok]      %s\n' "${tag}"
    else
      printf '   [missing] %s\n' "${tag}"
      missing=1
    fi
  done
  [[ "${missing}" -eq 0 ]] || return 1

  if [[ "${has_buildx}" == "true" ]]; then
    docker buildx imagetools create -t "${target}" "${amd64_tag}" "${arm64_tag}"
    docker buildx imagetools inspect "${target}"
  else
    docker manifest rm "${target}" >/dev/null 2>&1 || true
    docker manifest create "${manifest_args[@]}" "${target}" \
      --amend "${amd64_tag}" --amend "${arm64_tag}"
    docker manifest push "${manifest_args[@]}" "${target}"
    docker manifest inspect "${manifest_args[@]}" "${target}" \
      | grep -E '"architecture"|"os"' | sed 's/^[[:space:]]*/   /'
  fi
}

ecr_login() {
  is_ecr_registry || { log "非 ECR registry（${REGISTRY_HOST}），跳过登录"; return 0; }
  need aws
  log "登录 ECR：${REGISTRY_HOST}"
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${REGISTRY_HOST}"
}

# 按 CLUSTER_NAME / AWS_REGION 渲染 eksctl 配置，输出渲染后的文件路径。
# 用法：render_eksctl_config [相对仓库根的配置路径]，默认 infra/cluster.yaml。
# 换区域时会去掉硬编码的可用区，交给 eksctl 自动选择。
render_eksctl_config() {
  local rel="${1:-infra/cluster.yaml}"
  local src="${REPO_ROOT}/${rel}"
  local rendered="${BUILD_DIR}/$(basename "${rel}" .yaml).rendered.yaml"
  mkdir -p "${BUILD_DIR}"
  [[ -f "${src}" ]] || die "找不到配置文件：${src}"

  if command -v python3 >/dev/null 2>&1 && python3 -c 'import yaml' >/dev/null 2>&1; then
    python3 - "${src}" "${rendered}" "${CLUSTER_NAME}" "${AWS_REGION}" <<'PY'
import sys, yaml
src, dst, name, region = sys.argv[1:5]
cfg = yaml.safe_load(open(src))
cfg["metadata"]["name"] = name
cfg["metadata"]["region"] = region
if region != "us-east-1":
    cfg.pop("availabilityZones", None)
yaml.safe_dump(cfg, open(dst, "w"), sort_keys=False, allow_unicode=True)
PY
  else
    # 没有 python3 + PyYAML 时退化为 sed 替换
    sed -e "s|^  name: multi-arch-demo$|  name: ${CLUSTER_NAME}|" \
        -e "s|^  region: us-east-1$|  region: ${AWS_REGION}|" \
        "${src}" > "${rendered}"
    if [[ "${AWS_REGION}" != "us-east-1" ]]; then
      warn "未检测到 python3 + PyYAML：infra/cluster.yaml 里的 availabilityZones 仍是 us-east-1 的，"
      warn "换区域时请手工修改，或安装 PyYAML（pip3 install pyyaml）后重跑"
    fi
  fi

  echo "${rendered}"
}

# 兼容旧名字
render_cluster_config() { render_eksctl_config "infra/cluster.yaml"; }

# ---------------------------------------------------------------------------
# 机型架构判定：向 EC2 API 查，不猜机型名前缀。
#
# 为什么必须查 API：eksctl 是按**硬编码的 Graviton 机型家族列表**（a1/t4g/m6g/c6g/
# c7g/c8g/...）推断架构的，遇到列表里没有的新家族（例如 c9g）会当成 x86，
# 进而给托管节点组填 amiType=AL2023_x86_64_STANDARD，EKS 直接报：
#   [c9g.xlarge] is not a valid instance type for requested amiType AL2023_x86_64_STANDARD
# 这个错误在 `eksctl create nodegroup --dry-run` 阶段看不出来——dry-run 只回显配置里的
# amiFamily，真正的 amiType 是生成 CloudFormation 时才推断的。
# 参考：https://docs.aws.amazon.com/eks/latest/eksctl/arm-support.html
instance_arch() {
  local it="$1" arch_list
  need aws
  arch_list="$(aws ec2 describe-instance-types --instance-types "${it}" \
    --region "${AWS_REGION}" \
    --query 'InstanceTypes[0].ProcessorInfo.SupportedArchitectures' \
    --output text 2>/dev/null || true)"
  case "${arch_list}" in
    *arm64*)  echo arm64 ;;
    *x86_64*) echo x86_64 ;;
    *) die "无法确定机型 ${it} 的架构（区域 ${AWS_REGION}）。请确认机型名拼写正确、且该机型在本区域可用：
  aws ec2 describe-instance-type-offerings --location-type availability-zone \\
    --filters Name=instance-type,Values=${it} --region ${AWS_REGION}" ;;
  esac
}

# 架构 → EKS 托管节点组的 AL2023 amiType
eks_ami_type() {
  case "$1" in
    arm64)  echo AL2023_ARM_64_STANDARD ;;
    x86_64) echo AL2023_x86_64_STANDARD ;;
    *) die "未知架构：$1" ;;
  esac
}

# 从集群里已存在的任一节点组继承 nodeRole 与私有子网，
# 这样新增节点组不必再建 IAM 角色，也保证落在与现有节点相同的子网里。
# 输出两行：第 1 行 nodeRole ARN，第 2 行逗号分隔的 subnet id。
inherit_nodegroup_networking() {
  local src_ng
  src_ng="$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'nodegroups[0]' --output text 2>/dev/null || true)"
  [[ -n "${src_ng}" && "${src_ng}" != "None" ]] \
    || die "集群 ${CLUSTER_NAME} 里还没有任何节点组，无法继承 nodeRole/子网。请先执行 ./scripts/01-create-cluster.sh"
  aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${src_ng}" \
    --region "${AWS_REGION}" --query 'nodegroup.nodeRole' --output text
  aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --nodegroup-name "${src_ng}" \
    --region "${AWS_REGION}" --query 'join(`,`, nodegroup.subnets)' --output text
}

# 删除所有"不由 eksctl 管理"的托管节点组（即没有对应 CloudFormation 栈的）。
#
# 为什么需要：步骤 6 用 aws eks create-nodegroup 创建 Graviton 节点组（eksctl 会误判
# c9g 架构），这类节点组不属于任何 eksctl 栈。而 EKS 的 DeleteCluster 要求**先删完所有
# 托管节点组**，否则报 ResourceInUseException。所以删集群前必须显式清掉它们。
# 参考：https://docs.aws.amazon.com/eks/latest/userguide/delete-cluster.html
delete_non_eksctl_nodegroups() {
  local ngs ng stack_status
  ngs="$(aws eks list-nodegroups --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --query 'nodegroups[]' --output text 2>/dev/null || true)"
  [[ -n "${ngs}" && "${ngs}" != "None" ]] || return 0

  for ng in ${ngs}; do
    stack_status="$(aws cloudformation describe-stacks \
      --stack-name "eksctl-${CLUSTER_NAME}-nodegroup-${ng}" --region "${AWS_REGION}" \
      --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
    if [[ -n "${stack_status}" && "${stack_status}" != "None" ]]; then
      log "节点组 ${ng} 由 eksctl 管理（栈 ${stack_status}），交给 eksctl 删除"
      continue
    fi
    warn "节点组 ${ng} 没有 eksctl 栈（由 aws CLI 创建），先用 API 删除它"
    aws eks delete-nodegroup --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --nodegroup-name "${ng}" >/dev/null 2>&1 || { warn "删除 ${ng} 失败"; continue; }
    aws eks wait nodegroup-deleted --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --nodegroup-name "${ng}" || warn "等待 ${ng} 删除超时"
  done
}

# 清理上一次失败尝试留下的 CloudFormation 栈。
# 只处理明确处于"已死"状态的栈（里面没有存活资源），其他状态一律不动。
clean_failed_nodegroup_stack() {
  local ng="$1" stack="eksctl-${CLUSTER_NAME}-nodegroup-$1" status
  command -v aws >/dev/null 2>&1 || return 0
  status="$(aws cloudformation describe-stacks --stack-name "${stack}" --region "${AWS_REGION}" \
    --query 'Stacks[0].StackStatus' --output text 2>/dev/null || true)"
  [[ -n "${status}" && "${status}" != "None" ]] || return 0
  case "${status}" in
    ROLLBACK_COMPLETE|CREATE_FAILED|ROLLBACK_FAILED|DELETE_FAILED)
      warn "发现上次失败留下的 CloudFormation 栈 ${stack}（${status}），先删除它再重建"
      aws cloudformation delete-stack --stack-name "${stack}" --region "${AWS_REGION}"
      aws cloudformation wait stack-delete-complete --stack-name "${stack}" \
        --region "${AWS_REGION}" 2>/dev/null || warn "等待栈删除超时，请到 CloudFormation 控制台确认"
      ;;
    *)
      die "CloudFormation 栈 ${stack} 当前状态为 ${status}，不是失败状态。
请先自行确认它的归属再重试（避免误删正在使用的资源）。" ;;
  esac
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
