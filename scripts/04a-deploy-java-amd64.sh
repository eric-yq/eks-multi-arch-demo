#!/usr/bin/env bash
# 步骤 4a：把 Java 服务部署到 **x86 节点组**。
#
# 这一步对应客户现状：一个纯 x86 的 EKS 集群，服务只跑在 x86 节点上。
# 同时会创建命名空间与 Service（Service 的 selector 只认 app 标签，
# 后面 arm64 的 Pod 起来后会自动加入同一个后端，不需要再改 Service）。
#
# 部署到 Graviton 是 04b，但要先有 Graviton 节点组（06）。完整顺序见文件末尾提示。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

DEPLOY_NAME="java-arch-demo-amd64"

need kubectl; need aws
resolve_image_uri

log "更新 kubeconfig：${CLUSTER_NAME} (${AWS_REGION})"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

# 集群里必须有 x86 节点，否则 Pod 会一直 Pending
if ! kubectl get nodes -l kubernetes.io/arch=amd64 -o name 2>/dev/null | grep -q node; then
  die "集群里没有 amd64 节点，请先执行 ./scripts/01-create-cluster.sh"
fi

log "创建命名空间：${NAMESPACE}"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"

log "部署 x86 (amd64) Pod，镜像：${IMAGE_URI}"
for manifest in deployment-amd64.yaml service.yaml; do
  sed "s|IMAGE_PLACEHOLDER|${IMAGE_URI}|g" "${K8S_DIR}/${manifest}" | kubectl apply -f -
done

log "等待滚动更新完成"
kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOY_NAME}" --timeout=5m

log "Pod 分布（当前应全部落在 x86 节点上）"
kubectl -n "${NAMESPACE}" get pods -o wide -L arch

cat <<EOF

完成。当前状态：服务跑在 x86 节点上。

演示顺序：
  ./scripts/05-verify.sh                # 验证现状（此时只有 amd64 一组）
  ./scripts/06-add-c7g-nodegroup.sh     # 增量①：只新增 Graviton 节点组，业务不动
  ./scripts/04b-deploy-java-arm64.sh    # 增量②：同一个镜像 tag 部署到 Graviton
  ./scripts/05-verify.sh                # 对比两种架构
EOF
