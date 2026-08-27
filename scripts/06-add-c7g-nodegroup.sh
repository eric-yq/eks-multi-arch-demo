#!/usr/bin/env bash
# 步骤 6：给已有集群新增一个 Graviton3 节点组（1 × c7g.xlarge），
#         并把同一个多架构镜像的 Java 服务部署到这个新节点组上。
#
# 前提：集群已存在，且镜像已推送（即已跑过 01 ~ 03/03a+03b）。
# 脚本是幂等的：节点组或 Deployment 已存在时会跳过创建、直接做滚动更新。
#
# 费用：多出 1 台 c7g.xlarge（us-east-1 按需约 $0.145/小时）。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

NODEGROUP_NAME="${C7G_NODEGROUP:-ng-graviton-c7g}"
INSTANCE_TYPE="c7g.xlarge"
DEPLOY_NAME="java-arch-demo-c7g"
MANIFEST="${K8S_DIR}/deployment-c7g.yaml"
PROBE_IMAGE="${PROBE_IMAGE:-public.ecr.aws/docker/library/alpine:3.22}"

need eksctl; need kubectl; need aws
resolve_image_uri

log "集群 ${CLUSTER_NAME}（${AWS_REGION}）新增节点组 ${NODEGROUP_NAME}：${INSTANCE_TYPE} × 1"

eksctl get cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1 \
  || die "集群 ${CLUSTER_NAME} 不存在，请先执行 ./scripts/01-create-cluster.sh"

log "更新 kubeconfig"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

# ---------- 1) 创建节点组 ----------
if eksctl get nodegroup --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
      --name "${NODEGROUP_NAME}" >/dev/null 2>&1; then
  log "节点组 ${NODEGROUP_NAME} 已存在，跳过创建"
else
  RENDERED="$(render_cluster_config)"
  grep -q "name: ${NODEGROUP_NAME}" "${RENDERED}" \
    || die "infra/cluster.yaml 中找不到节点组 ${NODEGROUP_NAME}"

  warn "即将启动 1 台 ${INSTANCE_TYPE}（约 \$0.145/小时），预计 3~5 分钟"
  eksctl create nodegroup -f "${RENDERED}" --include="${NODEGROUP_NAME}"
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

log "当前全部节点"
kubectl get nodes \
  -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup

# ---------- 3) 部署到新节点组 ----------
log "部署 ${DEPLOY_NAME}（镜像沿用多架构 tag：${IMAGE_URI}）"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"
sed "s|IMAGE_PLACEHOLDER|${IMAGE_URI}|g" "${MANIFEST}" | kubectl apply -f -
kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOY_NAME}" --timeout=5m

# 确保 Service 仍然同时选中三组 Pod（幂等）
kubectl apply -f "${K8S_DIR}/service.yaml" >/dev/null

# ---------- 4) 验证 ----------
log "新节点组上的 Pod"
kubectl -n "${NAMESPACE}" get pods -o wide -l "arch=arm64-c7g"

log "容器内的真实架构（uname -m）"
for pod in $(kubectl -n "${NAMESPACE}" get pods -l "arch=arm64-c7g" -o name); do
  arch="$(kubectl -n "${NAMESPACE}" exec "${pod}" -- uname -m 2>/dev/null || echo '读取失败')"
  node="$(kubectl -n "${NAMESPACE}" get "${pod}" -o jsonpath='{.spec.nodeName}')"
  printf '   %-45s %-10s %s\n' "${pod#pod/}" "${arch}" "${node}"
done

POD_IP="$(kubectl -n "${NAMESPACE}" get pod -l "arch=arm64-c7g" \
  -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
if [[ -n "${POD_IP}" ]]; then
  log "直接访问 c7g 上的 Pod：/api/info"
  kubectl -n "${NAMESPACE}" run c7g-probe --rm -i --restart=Never --quiet \
    --image="${PROBE_IMAGE}" --command -- \
    sh -c "wget -qO- http://${POD_IP}:8080/api/info; echo" \
    || warn "采样失败（Pod 可能还在启动）"
fi

log "Service 后端在三个节点组上的分布"
kubectl -n "${NAMESPACE}" get pods -l app=java-arch-demo \
  -o custom-columns='POD:.metadata.name,ARCH:.metadata.labels.arch,NODE:.spec.nodeName' --no-headers \
  | sort -k2

cat <<EOF

完成。要点：
  - 新节点组 ${NODEGROUP_NAME}（${INSTANCE_TYPE}，Graviton3）已加入集群
  - ${DEPLOY_NAME} 用的是与 x86/c6g 完全相同的镜像 tag：${IMAGE_URI}
  - 落点由 nodeSelector 决定：kubernetes.io/arch=arm64 + node.kubernetes.io/instance-type=${INSTANCE_TYPE}
  - Service java-arch-demo 现在同时转发到 c6a / c6g / c7g 三组 Pod

对比三种实例的 CPU 表现（同一份 jar、同一个镜像）：
  ./scripts/05-verify.sh
  kubectl -n ${NAMESPACE} port-forward deploy/${DEPLOY_NAME} 8080:8080
  curl -s 'localhost:8080/api/bench?iterations=2000000'

只删除这个节点组（保留集群）：
  eksctl delete nodegroup --cluster ${CLUSTER_NAME} --region ${AWS_REGION} --name ${NODEGROUP_NAME}
  或：DELETE_C7G=true ./scripts/90-cleanup.sh
EOF
