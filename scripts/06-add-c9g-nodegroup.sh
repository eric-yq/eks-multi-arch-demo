#!/usr/bin/env bash
# 步骤 6（增量演示）：在已有的 **纯 x86** 集群上新增一个 Graviton 节点组
#                    （1 x c9g.xlarge）。只加节点，不动任何业务负载。
#
# 加节点组与部署业务分成两个脚本，是为了在客户面前把因果讲清楚：
#   06  只加节点组 → 此时 Graviton 节点是空的，业务还全在 x86 上
#   04b 部署业务   → 同一个镜像 tag，只改 nodeSelector，Pod 就落到 Graviton 上
#
# 前提：已完成 01（建集群）。脚本幂等：节点组已存在时跳过创建，只做就绪检查。
# 本脚本不需要镜像，也不需要 ECR 权限。
#
# 费用：多出 1 台 c9g.xlarge（us-east-1 按需约 $0.17388/小时）。
#
# 想换成 Graviton2 (c6g) 做对比：
#   C9G_NODEGROUP=ng-graviton-c6g C9G_INSTANCE_TYPE=c6g.xlarge ./scripts/06-add-c9g-nodegroup.sh
#
# 创建方式：默认用 `aws eks create-nodegroup` 并**显式指定 amiType**，
# 而不是 `eksctl create nodegroup`。原因见 env.sh 里 instance_arch() 的注释——
# eksctl 按硬编码的机型家族列表推断架构，c9g 这类新家族会被误判成 x86，
# 报 "[c9g.xlarge] is not a valid instance type for requested amiType AL2023_x86_64_STANDARD"。
# 这里改成先查 EC2 API 拿到权威架构，再把 amiType 明确传给 EKS，任何新机型都不会踩坑。
#
# 如果你的 eksctl 版本已经认识目标机型（c6g/c7g/c8g 等），可以走 eksctl 路径：
#   USE_EKSCTL=true ./scripts/06-add-c9g-nodegroup.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

NODEGROUP_NAME="${C9G_NODEGROUP:-ng-graviton-c9g}"
INSTANCE_TYPE="${C9G_INSTANCE_TYPE:-c9g.xlarge}"
NODEGROUP_FILE="${NODEGROUP_FILE:-infra/nodegroup-c9g.yaml}"
USE_EKSCTL="${USE_EKSCTL:-false}"
NODE_DISK_SIZE="${NODE_DISK_SIZE:-50}"

need kubectl; need aws
[[ "${USE_EKSCTL}" == "true" ]] && need eksctl

log "集群 ${CLUSTER_NAME}（${AWS_REGION}）新增节点组 ${NODEGROUP_NAME}：${INSTANCE_TYPE} × 1"

aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || die "集群 ${CLUSTER_NAME} 不存在，请先执行 ./scripts/01-create-cluster.sh"

log "更新 kubeconfig"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

log "改造前的节点与 Pod 分布（现场对照用）"
kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup
kubectl -n "${NAMESPACE}" get pods -o wide -L arch 2>/dev/null || true

# ---------- 1) 创建 Graviton 节点组 ----------
if aws eks describe-nodegroup --cluster-name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --nodegroup-name "${NODEGROUP_NAME}" >/dev/null 2>&1; then
  log "节点组 ${NODEGROUP_NAME} 已存在，跳过创建"
elif [[ "${USE_EKSCTL}" == "true" ]]; then
  RENDERED="$(render_eksctl_config "${NODEGROUP_FILE}")"
  grep -q "name: ${NODEGROUP_NAME}" "${RENDERED}" \
    || die "${NODEGROUP_FILE} 中找不到节点组 ${NODEGROUP_NAME}"
  clean_failed_nodegroup_stack "${NODEGROUP_NAME}"
  warn "即将启动 1 台 ${INSTANCE_TYPE}，预计 3~5 分钟（eksctl 路径）"
  eksctl create nodegroup -f "${RENDERED}"
else
  # 查权威架构 → 显式 amiType，绕开 eksctl 的机型家族猜测
  ARCH="$(instance_arch "${INSTANCE_TYPE}")"
  AMI_TYPE="$(eks_ami_type "${ARCH}")"
  log "机型 ${INSTANCE_TYPE} 架构 = ${ARCH}（EC2 API 查得），amiType = ${AMI_TYPE}"

  case "${ARCH}" in
    arm64)  DEMO_ARCH=arm64; DEMO_CPU="${DEMO_CPU:-aws-graviton5}" ;;
    x86_64) DEMO_ARCH=amd64; DEMO_CPU="${DEMO_CPU:-intel-x86}" ;;
  esac

  clean_failed_nodegroup_stack "${NODEGROUP_NAME}"

  # nodeRole 与子网继承自集群里已有的节点组，不额外创建 IAM 角色
  { read -r NODE_ROLE; read -r NODE_SUBNETS; } < <(inherit_nodegroup_networking)
  [[ -n "${NODE_ROLE}" && "${NODE_ROLE}" != "None" ]] || die "未能取得 nodeRole"
  log "继承 nodeRole：${NODE_ROLE##*/}"
  log "继承子网：${NODE_SUBNETS}"

  warn "即将启动 1 台 ${INSTANCE_TYPE}（约 \$0.17388/小时），预计 3~5 分钟"
  aws eks create-nodegroup \
    --cluster-name "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --nodegroup-name "${NODEGROUP_NAME}" \
    --node-role "${NODE_ROLE}" \
    --subnets ${NODE_SUBNETS//,/ } \
    --instance-types "${INSTANCE_TYPE}" \
    --ami-type "${AMI_TYPE}" \
    --capacity-type ON_DEMAND \
    --disk-size "${NODE_DISK_SIZE}" \
    --scaling-config minSize=1,maxSize=2,desiredSize=1 \
    --labels "demo.arch=${DEMO_ARCH},demo.cpu=${DEMO_CPU},demo.nodegroup=${NODEGROUP_NAME},workload=java-demo" \
    --tags "nodegroup-arch=${DEMO_ARCH},nodegroup-instance-type=${INSTANCE_TYPE}" \
    >/dev/null

  log "节点组创建中，等待变为 ACTIVE（这一步 3~5 分钟）"
  aws eks wait nodegroup-active --cluster-name "${CLUSTER_NAME}" \
    --nodegroup-name "${NODEGROUP_NAME}" --region "${AWS_REGION}" \
    || die "节点组创建失败。查看原因：
  aws eks describe-nodegroup --cluster-name ${CLUSTER_NAME} \\
    --nodegroup-name ${NODEGROUP_NAME} --region ${AWS_REGION} \\
    --query 'nodegroup.health.issues'"
fi

# ---------- 2) 等节点注册并就绪 ----------
log "等待节点加入集群"
for _ in $(seq 1 60); do
  node_count="$(kubectl get nodes -l "eks.amazonaws.com/nodegroup=${NODEGROUP_NAME}" \
    -o name 2>/dev/null | wc -l | tr -d ' ')"
  [[ "${node_count}" -ge 1 ]] && break
  sleep 10
done
[[ "${node_count:-0}" -ge 1 ]] || die "等待超时：没有节点带上标签 eks.amazonaws.com/nodegroup=${NODEGROUP_NAME}"

kubectl wait --for=condition=Ready node \
  -l "eks.amazonaws.com/nodegroup=${NODEGROUP_NAME}" --timeout=10m

log "现在集群里同时有 x86 与 Graviton 节点"
kubectl get nodes \
  -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup

log "Graviton 节点上目前还没有业务 Pod（下一步才部署）"
kubectl -n "${NAMESPACE}" get pods -o wide -L arch 2>/dev/null || true

cat <<EOF

节点组 ${NODEGROUP_NAME}（${INSTANCE_TYPE}）已就绪，业务负载尚未变动。

下一步：
  ./scripts/04b-deploy-java-arm64.sh   # 把同一个镜像 tag 部署到 Graviton 节点组
EOF
