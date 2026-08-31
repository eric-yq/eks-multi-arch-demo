#!/usr/bin/env bash
# 步骤 6a（增量演示，第一步）：在已有的 **纯 x86** 集群上新增一个 Graviton 节点组
#                              （1 x c7g.xlarge）。只加节点，不动任何业务负载。
#
# 拆成两步是为了在客户面前把因果讲清楚：
#   6a 只加节点组 → 此时 Graviton 节点是空的，业务还全在 x86 上
#   6b 部署业务   → 同一个镜像 tag，只改 nodeSelector，Pod 就落到 Graviton 上
#
# 前提：已完成 01（建集群）。脚本幂等：节点组已存在时跳过创建，只做就绪检查。
# 本脚本不需要镜像，也不需要 ECR 权限。
#
# 费用：多出 1 台 c7g.xlarge（us-east-1 按需约 $0.145/小时）。
#
# 想换成 Graviton2 (c6g) 做对比：
#   NODEGROUP_FILE=infra/nodegroup-c6g.yaml C7G_NODEGROUP=ng-graviton-c6g \
#   C7G_INSTANCE_TYPE=c6g.xlarge ./scripts/06a-add-c7g-nodegroup.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

NODEGROUP_NAME="${C7G_NODEGROUP:-ng-graviton-c7g}"
INSTANCE_TYPE="${C7G_INSTANCE_TYPE:-c7g.xlarge}"
NODEGROUP_FILE="${NODEGROUP_FILE:-infra/nodegroup-c7g.yaml}"

need eksctl; need kubectl; need aws

log "集群 ${CLUSTER_NAME}（${AWS_REGION}）新增节点组 ${NODEGROUP_NAME}：${INSTANCE_TYPE} × 1"

eksctl get cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || die "集群 ${CLUSTER_NAME} 不存在，请先执行 ./scripts/01-create-cluster.sh"

log "更新 kubeconfig"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

log "改造前的节点与 Pod 分布（现场对照用）"
kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup
kubectl -n "${NAMESPACE}" get pods -o wide -L arch 2>/dev/null || true

# ---------- 1) 创建 Graviton 节点组 ----------
if eksctl get nodegroup --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --name "${NODEGROUP_NAME}" >/dev/null 2>&1; then
  log "节点组 ${NODEGROUP_NAME} 已存在，跳过创建"
else
  RENDERED="$(render_eksctl_config "${NODEGROUP_FILE}")"
  grep -q "name: ${NODEGROUP_NAME}" "${RENDERED}" \
    || die "${NODEGROUP_FILE} 中找不到节点组 ${NODEGROUP_NAME}"

  warn "即将启动 1 台 ${INSTANCE_TYPE}（约 \$0.145/小时），预计 3~5 分钟"
  eksctl create nodegroup -f "${RENDERED}"
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
  ./scripts/06b-deploy-java-arm64.sh   # 把同一个镜像 tag 部署到 Graviton 节点组
EOF
