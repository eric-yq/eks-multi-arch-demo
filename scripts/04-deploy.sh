#!/usr/bin/env bash
# 步骤 4：把 Java 服务部署到 **x86 节点组**（此时集群里只有 x86 节点）
#
# 这一步对应客户现状：一个纯 x86 的 EKS 集群，服务跑在 x86 节点上。
# Graviton 节点组与对应的 Pod 是后面的增量步骤：./scripts/06-add-c7g-nodegroup.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need kubectl; need aws
resolve_image_uri

log "更新 kubeconfig：${CLUSTER_NAME} (${AWS_REGION})"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

log "创建命名空间：${NAMESPACE}"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"

log "部署 x86 (amd64) Pod，镜像：${IMAGE_URI}"
for manifest in deployment-amd64.yaml service.yaml; do
  sed "s|IMAGE_PLACEHOLDER|${IMAGE_URI}|g" "${K8S_DIR}/${manifest}" | kubectl apply -f -
done

log "等待滚动更新完成"
kubectl -n "${NAMESPACE}" rollout status deployment/java-arch-demo-amd64 --timeout=5m

log "Pod 分布（当前应全部落在 x86 节点上）"
kubectl -n "${NAMESPACE}" get pods -o wide -L arch

cat <<EOF

完成。当前状态：集群只有 x86 节点组，服务只跑在 x86 节点上。

下一步：
  ./scripts/05-verify.sh              # 验证现状
  ./scripts/06-add-c7g-nodegroup.sh   # 增量：新增 Graviton 节点组并把同一个镜像部署上去
EOF
