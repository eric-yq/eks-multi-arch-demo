#!/usr/bin/env bash
# 步骤 5：验证同一个镜像分别跑在 x86 与 Graviton 节点上
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need kubectl
PROBE_IMAGE="${PROBE_IMAGE:-public.ecr.aws/docker/library/alpine:3.22}"

log "1) 节点架构与实例类型"
kubectl get nodes \
  -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup

log "2) Pod 落点"
kubectl -n "${NAMESPACE}" get pods -o wide -L arch

log "3) 每个 Pod 容器内的真实架构（uname -m）"
for pod in $(kubectl -n "${NAMESPACE}" get pods -l app=java-arch-demo -o name); do
  arch="$(kubectl -n "${NAMESPACE}" exec "${pod}" -- uname -m 2>/dev/null || echo '读取失败')"
  node="$(kubectl -n "${NAMESPACE}" get "${pod}" -o jsonpath='{.spec.nodeName}')"
  printf '   %-45s %-10s %s\n' "${pod#pod/}" "${arch}" "${node}"
done

log "4) 通过 Service 访问 10 次，统计返回的架构分布"
kubectl -n "${NAMESPACE}" run arch-probe --rm -i --restart=Never --quiet \
  --image="${PROBE_IMAGE}" --command -- \
  sh -c 'for i in $(seq 1 10); do wget -qO- http://java-arch-demo/api/info | grep -o "\"osArch\":\"[^\"]*\""; done | sort | uniq -c' \
  || warn "Service 采样失败（可稍后重试）"

if [[ "${RUN_BENCH:-true}" == "true" ]]; then
  AMD_IP="$(kubectl -n "${NAMESPACE}" get pod -l app=java-arch-demo,arch=amd64 \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"
  ARM_IP="$(kubectl -n "${NAMESPACE}" get pod -l app=java-arch-demo,arch=arm64 \
    -o jsonpath='{.items[0].status.podIP}' 2>/dev/null || true)"

  if [[ -n "${AMD_IP}" && -n "${ARM_IP}" ]]; then
    log "5) 粗略 CPU 对比（SHA-256 循环，仅供参考，非正式基准测试）"
    kubectl -n "${NAMESPACE}" run bench-probe --rm -i --restart=Never --quiet \
      --image="${PROBE_IMAGE}" --command -- \
      sh -c "echo '--- c6a.xlarge (amd64) ---'; wget -qO- 'http://${AMD_IP}:8080/api/bench?iterations=2000000'; echo; echo '--- c6g.xlarge (arm64/Graviton) ---'; wget -qO- 'http://${ARM_IP}:8080/api/bench?iterations=2000000'; echo" \
      || warn "压测采样失败"
  else
    warn "未同时找到两种架构的 Pod，跳过 CPU 对比"
  fi
fi

log "本地访问服务：kubectl -n ${NAMESPACE} port-forward svc/java-arch-demo 8080:80  然后打开 http://localhost:8080/"
