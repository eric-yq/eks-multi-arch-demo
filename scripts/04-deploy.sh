#!/usr/bin/env bash
# 步骤 4：把 Java 服务同时部署到 x86 节点与 Graviton 节点
#
# 两个 Deployment 使用完全相同的镜像 tag，只靠 nodeSelector 里的
# kubernetes.io/arch 区分落点；一个 Service 同时选中两组 Pod。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need kubectl; need aws
resolve_image_uri

log "更新 kubeconfig：${CLUSTER_NAME} (${AWS_REGION})"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

log "创建命名空间：${NAMESPACE}"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml"

log "部署 x86 (amd64) 与 Graviton (arm64) 两组 Pod，镜像：${IMAGE_URI}"
for manifest in deployment-amd64.yaml deployment-arm64.yaml service.yaml; do
  sed "s|IMAGE_PLACEHOLDER|${IMAGE_URI}|g" "${K8S_DIR}/${manifest}" | kubectl apply -f -
done

log "等待滚动更新完成"
kubectl -n "${NAMESPACE}" rollout status deployment/java-arch-demo-amd64 --timeout=5m
kubectl -n "${NAMESPACE}" rollout status deployment/java-arch-demo-arm64 --timeout=5m

log "Pod 分布"
kubectl -n "${NAMESPACE}" get pods -o wide -L arch

log "完成。下一步：./scripts/05-verify.sh"
