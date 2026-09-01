#!/usr/bin/env bash
# 步骤 8a：把多语言服务（Go / Python / C++）部署到 **x86 节点组**。
#
# 前提：已完成 07a（两台机器各自原生构建并推送）与 07b（合并 manifest list）。
# 同时会创建命名空间与 Service（selector 只认 app 标签，
# 后面 arm64 的 Pod 起来后会自动加入同一个后端）。
#
# 跨架构的三语言压测对比在 ./scripts/09-verify-polyglot.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

DEPLOY_NAME="polyglot-demo-amd64"

need kubectl; need aws
resolve_polyglot_image_uri

log "更新 kubeconfig：${CLUSTER_NAME} (${AWS_REGION})"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

if ! kubectl get nodes -l kubernetes.io/arch=amd64 -o name 2>/dev/null | grep -q node; then
  die "集群里没有 amd64 节点，请先执行 ./scripts/01-create-cluster.sh"
fi

log "命名空间：${NAMESPACE}"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml" >/dev/null

log "部署 ${DEPLOY_NAME}，镜像：${POLYGLOT_IMAGE_URI}"
sed "s|IMAGE_PLACEHOLDER|${POLYGLOT_IMAGE_URI}|g" \
  "${POLYGLOT_K8S_DIR}/deployment-amd64.yaml" | kubectl apply -f -
kubectl apply -f "${POLYGLOT_K8S_DIR}/service.yaml" >/dev/null

log "等待滚动更新完成"
kubectl -n "${NAMESPACE}" rollout status "deployment/${DEPLOY_NAME}" --timeout=5m

log "Pod 落点"
kubectl -n "${NAMESPACE}" get pods -o wide -l "app=polyglot-arch-demo,arch=amd64" -L arch

log "Pod 内三种语言的运行时版本"
for pod in $(kubectl -n "${NAMESPACE}" get pods -l "app=polyglot-arch-demo,arch=amd64" -o name); do
  node="$(kubectl -n "${NAMESPACE}" get "${pod}" -o jsonpath='{.spec.nodeName}')"
  printf '   %s  (%s)\n' "${pod#pod/}" "${node}"
  kubectl -n "${NAMESPACE}" exec "${pod}" -- sh -c '
    printf "      uname -m : %s\n" "$(uname -m)"
    printf "      Go 服务  : 已作为 PID 1 运行\n"
    printf "      C++      : %s\n" "$(/app/bench-cpp --version)"
    printf "      Python   : %s\n" "$(python3 /app/bench.py --version)"
  ' 2>/dev/null || warn "读取 ${pod} 运行时信息失败"
done

cat <<EOF

完成。多语言服务已部署到 x86 节点组。

下一步：
  ./scripts/06-add-c9g-nodegroup.sh        # 若还没有 Graviton 节点组
  ./scripts/08b-deploy-polyglot-arm64.sh   # 部署到 Graviton（同一个镜像 tag）
  ./scripts/09-verify-polyglot.sh          # 三语言 × 两架构 压测对比

本地访问：
  kubectl -n ${NAMESPACE} port-forward svc/polyglot-arch-demo 8081:80
  curl -s localhost:8081/                                  # 三种语言的运行时概览
  curl -s 'localhost:8081/api/bench?lang=all' | jq         # 三语言压测
  curl -s 'localhost:8081/api/bench?lang=cpp&threads=1'    # 单语言、单线程
EOF
