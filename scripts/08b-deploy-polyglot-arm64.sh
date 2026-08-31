#!/usr/bin/env bash
# 步骤 8b：把多语言服务（Go / Python / C++）部署到 **Graviton (arm64) 节点组**。
#
# 与 08a 对称：同一个镜像 tag，只有 nodeSelector 不同。
# 但和 Java 服务不同的是，这个镜像里的 Go 与 C++ 是**原生编译**的产物，
# arm64 那一份来自 Graviton 实例上的构建（见 07a），由 manifest list 自动分发。
#
# 前提：Graviton 节点组已就绪（./scripts/06-add-c7g-nodegroup.sh）
#       且多架构镜像已合并（./scripts/07b-create-polyglot-manifest.sh）。
#
# 节点组名与实例类型默认从集群里的 arm64 节点自动读取（用于 /api/info 的展示字段），
# 也可用 C7G_NODEGROUP / C7G_INSTANCE_TYPE 覆盖。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

DEPLOY_NAME="polyglot-demo-arm64"

need kubectl; need aws
resolve_polyglot_image_uri

log "更新 kubeconfig：${CLUSTER_NAME} (${AWS_REGION})"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

ARM_NODE="$(kubectl get nodes -l kubernetes.io/arch=arm64 \
  -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
[[ -n "${ARM_NODE}" ]] || die "集群里没有 arm64 节点，请先执行 ./scripts/06-add-c7g-nodegroup.sh"

NODEGROUP_NAME="${C7G_NODEGROUP:-$(kubectl get node "${ARM_NODE}" \
  -o jsonpath='{.metadata.labels.eks\.amazonaws\.com/nodegroup}' 2>/dev/null || echo 'unknown')}"
INSTANCE_TYPE="${C7G_INSTANCE_TYPE:-$(kubectl get node "${ARM_NODE}" \
  -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo 'unknown')}"

log "目标：节点组 ${NODEGROUP_NAME}（${INSTANCE_TYPE}），节点 ${ARM_NODE}"

arm_count="$(kubectl get nodes -l kubernetes.io/arch=arm64 -o name | wc -l | tr -d ' ')"
if [[ "${arm_count}" -gt 1 ]]; then
  warn "集群里有 ${arm_count} 个 arm64 节点，nodeSelector 只按架构选，Pod 可能落到任意一个"
fi

log "命名空间：${NAMESPACE}"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml" >/dev/null

log "部署 ${DEPLOY_NAME}，镜像与 x86 侧完全相同：${POLYGLOT_IMAGE_URI}"
sed -e "s|IMAGE_PLACEHOLDER|${POLYGLOT_IMAGE_URI}|g" \
    -e "s|NODEGROUP_PLACEHOLDER|${NODEGROUP_NAME}|g" \
    -e "s|INSTANCE_TYPE_PLACEHOLDER|${INSTANCE_TYPE}|g" \
  "${POLYGLOT_K8S_DIR}/deployment-arm64.yaml" | kubectl apply -f -
kubectl apply -f "${POLYGLOT_K8S_DIR}/service.yaml" >/dev/null

log "等待滚动更新完成"
kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOY_NAME}" --timeout=5m

log "Pod 落点"
kubectl -n "${NAMESPACE}" get pods -o wide -l "app=polyglot-arch-demo,arch=arm64" -L arch

log "Pod 内三种语言的运行时版本（注意 C++ 的架构后缀）"
for pod in $(kubectl -n "${NAMESPACE}" get pods -l "app=polyglot-arch-demo,arch=arm64" -o name); do
  node="$(kubectl -n "${NAMESPACE}" get "${pod}" -o jsonpath='{.spec.nodeName}')"
  printf '   %s  (%s)\n' "${pod#pod/}" "${node}"
  kubectl -n "${NAMESPACE}" exec "${pod}" -- sh -c '
    printf "      uname -m : %s\n" "$(uname -m)"
    printf "      C++      : %s\n" "$(/app/bench-cpp --version)"
    printf "      Python   : %s\n" "$(python3 /app/bench.py --version)"
  ' 2>/dev/null || warn "读取 ${pod} 运行时信息失败"
done

log "Service 后端在两个节点组上的分布"
kubectl -n "${NAMESPACE}" get pods -l app=polyglot-arch-demo \
  -o custom-columns='POD:.metadata.name,ARCH:.metadata.labels.arch,NODE:.spec.nodeName' --no-headers \
  | sort -k2

cat <<EOF

完成。多语言服务现在同时跑在 x86 与 Graviton 上，用的是同一个镜像 tag：
  ${POLYGLOT_IMAGE_URI}

给客户强调：Go 与 C++ 是原生二进制，两种架构各编译一次（07a），
合并成 manifest list 后（07b），部署侧和 Java 一样只改 nodeSelector。

下一步：
  ./scripts/09-verify-polyglot.sh   # 三语言 × 两架构 压测对比
EOF
