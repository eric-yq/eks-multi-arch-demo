#!/usr/bin/env bash
# 步骤 5：验证同一个镜像分别跑在 x86 与各代 Graviton 节点上
#
# 说明：Pod 上的 arch 标签是"部署分组标识"（amd64 / arm64 / arm64-c7g），
# 因为 Deployment 的 spec.selector 不可变，各组必须取不同的值才不会互相抢 Pod。
# 真实 CPU 架构看节点标签 kubernetes.io/arch 与容器内的 uname -m。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need kubectl
PROBE_IMAGE="${PROBE_IMAGE:-public.ecr.aws/docker/library/alpine:3.22}"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-2000000}"
APP_SELECTOR="app=java-arch-demo"

# 在集群内跑一个一次性探针 Pod 并取回输出。
# 不用 `kubectl run --rm -i`：那种写法要 attach 容器，容器启动/退出与 attach 存在竞争，
# 会出现 "couldn't attach to pod ... falling back to streaming logs" 并可能丢掉开头几行输出。
# 这里改成：创建 Pod → 等它跑完 → kubectl logs 取完整输出 → 删除。
run_probe() {
  local name="$1" cmd="$2" phase=""
  kubectl -n "${NAMESPACE}" delete pod "${name}" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kubectl -n "${NAMESPACE}" run "${name}" --restart=Never --image="${PROBE_IMAGE}" \
    --command -- sh -c "${cmd}" >/dev/null || { warn "探针 Pod ${name} 创建失败"; return 1; }

  for _ in $(seq 1 90); do
    phase="$(kubectl -n "${NAMESPACE}" get pod "${name}" -o jsonpath='{.status.phase}' 2>/dev/null || echo '')"
    [[ "${phase}" == "Succeeded" || "${phase}" == "Failed" ]] && break
    sleep 2
  done

  kubectl -n "${NAMESPACE}" logs "${name}" 2>/dev/null || warn "读取 ${name} 日志失败"
  kubectl -n "${NAMESPACE}" delete pod "${name}" --wait=false >/dev/null 2>&1 || true
  [[ "${phase}" == "Succeeded" ]] || warn "探针 Pod ${name} 未正常结束（phase=${phase:-unknown}）"
}

log "1) 节点架构与实例类型"
kubectl get nodes \
  -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup

# ---------- 节点信息缓存：node -> arch / instance-type / nodegroup ----------
declare -A NODE_ARCH NODE_TYPE NODE_NG
while read -r n a t g; do
  [[ -n "${n:-}" ]] || continue
  NODE_ARCH["${n}"]="${a}"; NODE_TYPE["${n}"]="${t}"; NODE_NG["${n}"]="${g}"
done < <(kubectl get nodes --no-headers -o custom-columns='\
N:.metadata.name,\
A:.metadata.labels.kubernetes\.io/arch,\
T:.metadata.labels.node\.kubernetes\.io/instance-type,\
G:.metadata.labels.eks\.amazonaws\.com/nodegroup')

log "2) Pod 落点（GROUP 是部署分组标签，NODE-ARCH/INSTANCE-TYPE 才是真实架构）"
printf '   %-40s %-11s %-10s %-14s %-18s %s\n' \
  POD GROUP NODE-ARCH INSTANCE-TYPE NODEGROUP NODE
while read -r pod group node; do
  [[ -n "${pod:-}" ]] || continue
  printf '   %-40s %-11s %-10s %-14s %-18s %s\n' \
    "${pod}" "${group}" "${NODE_ARCH[${node}]:-?}" "${NODE_TYPE[${node}]:-?}" \
    "${NODE_NG[${node}]:-?}" "${node}"
done < <(kubectl -n "${NAMESPACE}" get pods -l "${APP_SELECTOR}" --no-headers \
  -o custom-columns='P:.metadata.name,G:.metadata.labels.arch,N:.spec.nodeName' | sort -k2)

log "3) 每个 Pod 容器内的真实架构（uname -m）"
for pod in $(kubectl -n "${NAMESPACE}" get pods -l "${APP_SELECTOR}" -o name); do
  arch="$(kubectl -n "${NAMESPACE}" exec "${pod}" -- uname -m 2>/dev/null || echo '读取失败')"
  node="$(kubectl -n "${NAMESPACE}" get "${pod}" -o jsonpath='{.spec.nodeName}')"
  printf '   %-40s %-10s %-14s %s\n' \
    "${pod#pod/}" "${arch}" "${NODE_TYPE[${node}]:-?}" "${node}"
done

log "4) 通过 Service 访问 12 次，统计返回的架构与实例类型分布"
run_probe arch-probe '
for i in $(seq 1 12); do
  wget -qO- http://java-arch-demo/api/info \
    | grep -o "\"\(osArch\|nodeInstanceType\)\":\"[^\"]*\"" \
    | cut -d: -f2 | tr -d "\"" | paste -sd" " -
done | sort | uniq -c | sed "s/^/   /"' \
  || warn "Service 采样失败（可稍后重试）"

# ---------- 5) 逐个分组做 CPU 对比：自动发现所有分组，不再硬编码架构 ----------
if [[ "${RUN_BENCH:-true}" != "true" ]]; then
  log "已跳过 CPU 对比（RUN_BENCH=false）"
else
  targets=()          # 每项："分组|实例类型|PodIP|PodName"
  while read -r group; do
    [[ -n "${group:-}" ]] || continue
    read -r pod ip node < <(kubectl -n "${NAMESPACE}" get pods -l "${APP_SELECTOR},arch=${group}" \
      --field-selector status.phase=Running --no-headers \
      -o custom-columns='P:.metadata.name,I:.status.podIP,N:.spec.nodeName' | head -1)
    [[ -n "${ip:-}" ]] || continue
    targets+=("${group}|${NODE_TYPE[${node}]:-?}|${ip}|${pod}")
  done < <(kubectl -n "${NAMESPACE}" get pods -l "${APP_SELECTOR}" \
    -o jsonpath='{range .items[*]}{.metadata.labels.arch}{"\n"}{end}' | sort -u)

  if [[ "${#targets[@]}" -eq 0 ]]; then
    warn "5) 没有找到运行中的 Pod，跳过 CPU 对比"
  else
    log "5) 粗略 CPU 对比：${#targets[@]} 个分组 × ${BENCH_ITERATIONS} 次 SHA-256（仅供参考，非正式基准测试）"

    # 在一个探针 Pod 里依次压测每个分组，输出 "分组|实例类型|JSON" 便于解析。
    # 每组先跑一次丢弃结果：JIT 编译只在首次调用时发生，否则"冷"的那一组会明显偏慢。
    probe_cmd=""
    for t in "${targets[@]}"; do
      IFS='|' read -r group itype ip _pod <<<"${t}"
      probe_cmd+="wget -qO- 'http://${ip}:8080/api/bench?iterations=${BENCH_ITERATIONS}' >/dev/null 2>&1; "
      probe_cmd+="printf '%s|%s|' '${group}' '${itype}'; "
      probe_cmd+="wget -qO- 'http://${ip}:8080/api/bench?iterations=${BENCH_ITERATIONS}' || echo '{}'; echo; "
    done

    bench_raw="$(run_probe bench-probe "${probe_cmd}" || true)"

    if command -v python3 >/dev/null 2>&1; then
      printf '%s\n' "${bench_raw}" | python3 -c '
import json, re, sys

rows = []
for line in sys.stdin:
    parts = line.strip().split("|", 2)
    if len(parts) != 3 or not parts[2].startswith("{"):
        continue
    group, itype, payload = parts
    try:
        d = json.loads(payload)
    except json.JSONDecodeError:
        continue
    if "opsPerSecond" not in d:
        continue
    rows.append({
        "group": group,
        "itype": itype,
        "arch": d.get("osArch", "?"),
        "ms": d.get("elapsedMillis", 0),
        "ops": d.get("opsPerSecond", 0),
        "cpus": d.get("availableProcessors", "?"),
        "pod": d.get("podName", "?"),
    })

if not rows:
    sys.exit("   压测结果解析失败，原始输出见上方")

best = max(r["ops"] for r in rows) or 1
print("   {:<11} {:<14} {:<9} {:>10} {:>14} {:>8} {:>7}".format(
    "GROUP", "INSTANCE-TYPE", "OS-ARCH", "耗时(ms)", "ops/s", "相对", "vCPU"))
for r in sorted(rows, key=lambda x: -x["ops"]):
    print("   {:<11} {:<14} {:<9} {:>10} {:>14,} {:>7.0f}% {:>7}".format(
        r["group"], r["itype"], r["arch"], r["ms"], r["ops"],
        r["ops"] / best * 100, r["cpus"]))
print("   注：单线程负载，每组已先跑一轮丢弃以排除 JIT 预热；")
print("       vCPU 是容器可见核数（受 limits.cpu 限制），各组一致才有可比性。")
' || printf '%s\n' "${bench_raw}"
    else
      printf '%s\n' "${bench_raw}"
    fi
  fi
fi

log "本地访问服务：kubectl -n ${NAMESPACE} port-forward svc/java-arch-demo 8080:80  然后打开 http://localhost:8080/"
