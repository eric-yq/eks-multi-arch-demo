#!/usr/bin/env bash
# 步骤 1：创建 EKS 集群 + **一个 x86 节点组**（1 x c7i.xlarge）
#
# 对应客户现状：集群里只有 x86 节点。Graviton 节点组留到步骤 6 增量添加，
# 这样才能演示"存量 x86 集群如何引入 Graviton"。
#
# 注意：会产生真实费用（EKS 控制平面 + 1 台 EC2 + NAT 网关），耗时约 15~20 分钟。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need eksctl; need aws; need kubectl

log "集群：${CLUSTER_NAME}    区域：${AWS_REGION}"

if eksctl get cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  log "集群 ${CLUSTER_NAME} 已存在，跳过创建"
else
  RENDERED="$(render_eksctl_config infra/cluster.yaml)"
  log "已渲染配置 -> ${RENDERED}"
  warn "即将创建 EKS 集群，会产生费用，预计 15~20 分钟"
  eksctl create cluster -f "${RENDERED}"
fi

log "更新 kubeconfig"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

log "节点列表（此时应只有 1 个 amd64 / c7i.xlarge 节点）"
kubectl get nodes \
  -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup

log "完成。下一步：./scripts/02-build-jar.sh"
