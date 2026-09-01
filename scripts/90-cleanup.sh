#!/usr/bin/env bash
# 清理：默认只删除 Kubernetes 资源。
# 删除节点组 / ECR 仓库 / EKS 集群需要显式开关，避免误删：
#   DELETE_C9G=true ./scripts/90-cleanup.sh                      # 只删 c9g 节点组
#   DELETE_ECR=true DELETE_CLUSTER=true ./scripts/90-cleanup.sh  # 删仓库 + 整个集群
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need kubectl

log "删除命名空间 ${NAMESPACE} 内的 demo 资源（含可能创建的 NLB Service）"
kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true --wait=true || warn "命名空间删除失败或不存在"

if [[ "${DELETE_C9G:-false}" == "true" ]]; then
  need eksctl
  C9G_NODEGROUP="${C9G_NODEGROUP:-ng-graviton-c9g}"
  warn "删除节点组 ${C9G_NODEGROUP}（保留集群与其他节点组）"
  eksctl delete nodegroup --cluster "${CLUSTER_NAME}" --region "${AWS_REGION}" \
    --name "${C9G_NODEGROUP}" --wait || warn "节点组删除失败或不存在"
fi

if [[ "${DELETE_ECR:-false}" == "true" ]]; then
  need aws
  warn "删除 ECR 仓库 ${ECR_REPO}（含全部镜像，不可恢复）"
  aws ecr delete-repository --repository-name "${ECR_REPO}" --region "${AWS_REGION}" --force \
    || warn "ECR 仓库删除失败或不存在"
else
  log "保留 ECR 仓库 ${ECR_REPO}（如需删除：DELETE_ECR=true）"
fi

if [[ "${DELETE_CLUSTER:-false}" == "true" ]]; then
  need eksctl
  warn "删除 EKS 集群 ${CLUSTER_NAME}（含 2 个节点组、VPC、NAT 网关），耗时约 10~15 分钟"
  eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --wait
else
  log "保留 EKS 集群 ${CLUSTER_NAME}（如需删除：DELETE_CLUSTER=true）"
  warn "集群保留期间会持续计费：控制平面 + c7i.xlarge + c6g.xlarge + NAT 网关"
fi

log "清理完成"
