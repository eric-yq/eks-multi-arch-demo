#!/usr/bin/env bash
# 步骤 6b（增量演示，第二步）：把 Java 业务部署到 Graviton 节点组。
#
# 这一步是给客户看的核心：**镜像 tag 与 x86 侧完全相同**，
# 两个 Deployment 逐字对比只有 nodeSelector 一处不同，业务就跑到 Graviton 上了。
#
# 前提：已完成 06a（Graviton 节点组已就绪）与 02/03（多架构镜像已推送）。
# 脚本幂等：Deployment 已存在时只做滚动更新。
#
# 节点组名与实例类型默认从集群里的 arm64 节点自动读取（用于填 /api/info 的展示字段），
# 也可以用 C7G_NODEGROUP / C7G_INSTANCE_TYPE 覆盖。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

DEPLOY_NAME="java-arch-demo-arm64"
MANIFEST="${K8S_DIR}/deployment-arm64.yaml"
PROBE_IMAGE="${PROBE_IMAGE:-public.ecr.aws/docker/library/alpine:3.22}"

need kubectl; need aws
resolve_image_uri

log "更新 kubeconfig：${CLUSTER_NAME} (${AWS_REGION})"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

# ---------- 1) 确认集群里有 Graviton 节点 ----------
ARM_NODE="$(kubectl get nodes -l kubernetes.io/arch=arm64 \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${ARM_NODE}" ]] || die "集群里没有 arm64 节点，请先执行 ./scripts/06a-add-c7g-nodegroup.sh"

NODEGROUP_NAME="${C7G_NODEGROUP:-$(kubectl get node "${ARM_NODE}" \
  -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/nodegroup}' 2>/dev/null || echo 'unknown')}"
INSTANCE_TYPE="${C7G_INSTANCE_TYPE:-$(kubectl get node "${ARM_NODE}" \
  -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo 'unknown')}"

log "目标：节点组 ${NODEGROUP_NAME}（${INSTANCE_TYPE}），节点 ${ARM_NODE}"

arm_count="$(kubectl get nodes -l kubernetes.io/arch=arm64 -o name | wc -l | tr -d ' ')"
if [[ "${arm_count}" -gt 1 ]]; then
  warn "集群里有 ${arm_count} 个 arm64 节点组，deployment-arm64.yaml 的 nodeSelector 只按架构选，"
  warn "Pod 可能落到其中任意一个。要精确指定，在 manifest 里补一行 node.kubernetes.io/instance-type"
fi

# ---------- 2) 部署 ----------
log "部署 ${DEPLOY_NAME}：镜像与 x86 侧完全相同（${IMAGE_URI}），只改 nodeSelector"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml" >/dev/null
sed -e "s|IMAGE_PLACEHOLDER|${IMAGE_URI}|g" \
    -e "s|NODEGROUP_PLACEHOLDER|${NODEGROUP_NAME}|g" \
    -e "s|INSTANCE_TYPE_PLACEHOLDER|${INSTANCE_TYPE}|g" \
    "${MANIFEST}" | kubectl apply -f -
kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOY_NAME}" --timeout=5m

# Service 保持同时选中 x86 与 Graviton 两组 Pod（幂等）
kubectl apply -f "${K8S_DIR}/service.yaml" >/dev/null

# ---------- 3) 验证 ----------
log "Graviton 节点组上的 Pod"
kubectl -n "${NAMESPACE}" get pods -o wide -l "arch=arm64"

log "容器内的真实架构（uname -m）"
for pod in $(kubectl -n "${NAMESPACE}" get pods -l "arch=arm64" -o name); do
  arch="$(kubectl -n "${NAMESPACE}" exec "${pod}" -- uname -m 2>/dev/null || echo '读取失败')"
  node="$(kubectl -n "${NAMESPACE}" get "${pod}" -o jsonpath='{.spec.nodeName}')"
  printf '   %-45s %-10s %s\n' "${pod#pod/}" "${arch}" "${node}"
done

POD_IP="$(kubectl -n "${NAMESPACE}" get pod -l "arch=arm64" \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
if [[ -n "${POD_IP}" ]]; then
  log "直接访问 Graviton 上的 Pod：/api/info"
  run_probe c7g-probe "wget -qO- http://${POD_IP}:8080/api/info; echo" \
    || warn "采样失败（Pod 可能还在启动）"
fi

log "Service 后端在两个节点组上的分布"
kubectl -n "${NAMESPACE}" get pods -l app=java-arch-demo \
  -o custom-columns='POD:.metadata.name,ARCH:.metadata.labels.arch,NODE:.spec.nodeName' --no-headers \
  | sort -k2

cat <<EOF

完成。给客户强调这几点：
  - 集群、VPC、x86 节点组、Service 全都没动，只新增了节点组 ${NODEGROUP_NAME}（${INSTANCE_TYPE}）
  - ${DEPLOY_NAME} 与 java-arch-demo-amd64 用的是同一个镜像 tag：${IMAGE_URI}
    多架构 manifest list 让节点各自拉到匹配自己架构的那一份，无需改镜像地址
  - 两个 Deployment 的差异只有 nodeSelector：kubernetes.io/arch = amd64 / arm64
  - Service java-arch-demo 同时选中两组 Pod，流量已经在 x86 与 Graviton 之间分摊

对比两种架构的表现：
  ./scripts/05-verify.sh

灰度/迁移的下一步（可选）：
  k8s/deployment-mixed.yaml —— 一个 Deployment 用 topologySpreadConstraints 跨两种架构均匀分布

只删除这个节点组（保留集群与 x86 节点组）：
  eksctl delete nodegroup --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --name ${NODEGROUP_NAME}
  或：DELETE_C7G=true ./scripts/90-cleanup.sh
EOF
