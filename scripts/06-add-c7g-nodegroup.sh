#!/usr/bin/env bash
# 步骤 6（增量演示）：在已有的 **纯 x86** 集群上新增一个 Graviton 节点组（1 x c7g.xlarge），
#                     并把**完全相同的镜像 tag** 部署到这个新节点组上。
#
# 这就是给客户看的核心动作：存量集群不动、镜像不换、只加一个节点组 + 一个 nodeSelector，
# 业务就能跑在 Graviton 上。
#
# 前提：已完成 01（建集群）、02/03（构建并推送多架构镜像）、04（x86 上已有服务）。
# 脚本幂等：节点组或 Deployment 已存在时跳过创建、只做滚动更新。
#
# 费用：多出 1 台 c7g.xlarge（us-east-1 按需约 $0.145/小时）。
#
# 想换成 Graviton2 (c6g) 做对比：
#   NODEGROUP_FILE=infra/nodegroup-c6g.yaml C7G_NODEGROUP=ng-graviton-c6g \
#   C7G_INSTANCE_TYPE=c6g.xlarge ./scripts/06-add-c7g-nodegroup.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

NODEGROUP_NAME="${C7G_NODEGROUP:-ng-graviton-c7g}"
INSTANCE_TYPE="${C7G_INSTANCE_TYPE:-c7g.xlarge}"
NODEGROUP_FILE="${NODEGROUP_FILE:-infra/nodegroup-c7g.yaml}"
DEPLOY_NAME="java-arch-demo-arm64"
MANIFEST="${K8S_DIR}/deployment-arm64.yaml"
PROBE_IMAGE="${PROBE_IMAGE:-public.ecr.aws/docker/library/alpine:3.22}"

need eksctl; need kubectl; need aws
resolve_image_uri

log "集群 ${CLUSTER_NAME}（${AWS_REGION}）新增节点组 ${NODEGROUP_NAME}：${INSTANCE_TYPE} × 1"

eksctl get cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || die "集群 ${CLUSTER_NAME} 不存在，请先执行 ./scripts/01-create-cluster.sh"

log "更新 kubeconfig"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

log "改造前的节点与 Pod 分布"
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

# ---------- 3) 把同一个镜像部署到 Graviton 节点组 ----------
log "部署 ${DEPLOY_NAME}：镜像与 x86 完全相同（${IMAGE_URI}），只改 nodeSelector"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml" >/dev/null
sed -e "s|IMAGE_PLACEHOLDER|${IMAGE_URI}|g" \
    -e "s|NODEGROUP_PLACEHOLDER|${NODEGROUP_NAME}|g" \
    -e "s|INSTANCE_TYPE_PLACEHOLDER|${INSTANCE_TYPE}|g" \
    "${MANIFEST}" | kubectl apply -f -
kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOY_NAME}" --timeout=5m

# Service 保持同时选中 x86 与 Graviton 两组 Pod（幂等）
kubectl apply -f "${K8S_DIR}/service.yaml" >/dev/null

# ---------- 4) 验证 ----------
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
  kubectl -n "${NAMESPACE}" run c7g-probe --rm -i --restart=Never --quiet \
    --image="${PROBE_IMAGE}" --command -- \
    sh -c "wget -qO- http://${POD_IP}:8080/api/info; echo" \
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
