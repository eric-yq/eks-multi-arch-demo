#!/usr/bin/env bash
# 步骤 1：创建 EKS 集群 + 两个节点组（1 x c6a.xlarge、1 x c6g.xlarge）
#
# 注意：会产生真实费用（EKS 控制平面 + 2 台 EC2 + NAT 网关），耗时约 15~20 分钟。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need eksctl; need aws; need kubectl

log "集群：${CLUSTER_NAME}    区域：${AWS_REGION}"

if eksctl get cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  log "集群 ${CLUSTER_NAME} 已存在，跳过创建"
else
  mkdir -p "${BUILD_DIR}"
  RENDERED="${BUILD_DIR}/cluster.rendered.yaml"

  # 按 CLUSTER_NAME / AWS_REGION 渲染配置；换区域时移除硬编码的可用区，交给 eksctl 自动选择
  python3 - "$REPO_ROOT/infra/cluster.yaml" "$RENDERED" "$CLUSTER_NAME" "$AWS_REGION" <<'PY'
import sys, yaml
src, dst, name, region = sys.argv[1:5]
cfg = yaml.safe_load(open(src))
cfg["metadata"]["name"] = name
cfg["metadata"]["region"] = region
if region != "us-east-1":
    cfg.pop("availabilityZones", None)
yaml.safe_dump(cfg, open(dst, "w"), sort_keys=False, allow_unicode=True)
print(f"已渲染配置 -> {dst}")
PY

  warn "即将创建 EKS 集群，会产生费用，预计 15~20 分钟"
  eksctl create cluster -f "${RENDERED}"
fi

log "更新 kubeconfig"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

log "节点列表（关注 ARCH 与 INSTANCE-TYPE 列）"
kubectl get nodes \
  -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup

log "完成。下一步：./scripts/02-build-jar.sh"
