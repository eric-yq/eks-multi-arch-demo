#!/usr/bin/env bash
# 步骤 8：把多语言服务（Go / Python / C++）部署到 x86 与 Graviton 两个节点组，
#         并用同一个负载横向对比三种语言 × 两种架构。
#
# 前提：已完成 07a（两台机器各自原生构建并推送）与 07b（合并 manifest list）。
# 只部署 x86 一侧：SKIP_ARM64=true ./scripts/08-deploy-polyglot.sh
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need kubectl; need aws
resolve_polyglot_image_uri

GRAVITON_NODEGROUP="${C7G_NODEGROUP:-ng-graviton-c7g}"
GRAVITON_INSTANCE_TYPE="${C7G_INSTANCE_TYPE:-c7g.xlarge}"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-2000000}"
PROBE_IMAGE="${PROBE_IMAGE:-public.ecr.aws/docker/library/alpine:3.22}"

log "更新 kubeconfig：${CLUSTER_NAME} (${AWS_REGION})"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null

log "命名空间：${NAMESPACE}"
kubectl apply -f "${K8S_DIR}/00-namespace.yaml" >/dev/null

log "部署多语言服务，镜像：${POLYGLOT_IMAGE_URI}"
sed "s|IMAGE_PLACEHOLDER|${POLYGLOT_IMAGE_URI}|g" \
  "${POLYGLOT_K8S_DIR}/deployment-amd64.yaml" | kubectl apply -f -

if [[ "${SKIP_ARM64:-false}" != "true" ]]; then
  sed -e "s|IMAGE_PLACEHOLDER|${POLYGLOT_IMAGE_URI}|g" \
      -e "s|NODEGROUP_PLACEHOLDER|${GRAVITON_NODEGROUP}|g" \
      -e "s|INSTANCE_TYPE_PLACEHOLDER|${GRAVITON_INSTANCE_TYPE}|g" \
    "${POLYGLOT_K8S_DIR}/deployment-arm64.yaml" | kubectl apply -f -
fi

kubectl apply -f "${POLYGLOT_K8S_DIR}/service.yaml" >/dev/null

log "等待滚动更新完成"
kubectl -n "${NAMESPACE}" rollout status deployment/polyglot-demo-amd64 --timeout=5m
if [[ "${SKIP_ARM64:-false}" != "true" ]]; then
  kubectl -n "${NAMESPACE}" rollout status deployment/polyglot-demo-arm64 --timeout=5m
fi

log "Pod 落点"
kubectl -n "${NAMESPACE}" get pods -o wide -l app=polyglot-arch-demo -L arch

log "各 Pod 内三种语言的运行时版本"
for pod in $(kubectl -n "${NAMESPACE}" get pods -l app=polyglot-arch-demo -o name); do
  node="$(kubectl -n "${NAMESPACE}" get "${pod}" -o jsonpath='{.spec.nodeName}')"
  printf '   %s  (%s)\n' "${pod#pod/}" "${node}"
  kubectl -n "${NAMESPACE}" exec "${pod}" -- sh -c '
    printf "      uname -m : %s\n" "$(uname -m)"
    printf "      C++      : %s\n" "$(/app/bench-cpp --version)"
    printf "      Python   : %s\n" "$(python3 /app/bench.py --version)"
  ' 2>/dev/null || warn "读取 ${pod} 运行时信息失败"
done

# ---------- 三语言 × 两架构 压测对比 ----------
targets=()
while read -r group; do
  [[ -n "${group:-}" ]] || continue
  read -r pod ip node < <(kubectl -n "${NAMESPACE}" \
    get pods -l "app=polyglot-arch-demo,arch=${group}" \
    --field-selector status.phase=Running --no-headers \
    -o custom-columns='P:.metadata.name,I:.status.podIP,N:.spec.nodeName' | head -1)
  [[ -n "${ip:-}" ]] || continue
  itype="$(kubectl get node "${node}" \
    -o jsonpath='{.metadata.labels.node\.kubernetes\.io/instance-type}' 2>/dev/null || echo '?')"
  targets+=("${group}|${itype}|${ip}")
done < <(kubectl -n "${NAMESPACE}" get pods -l app=polyglot-arch-demo \
  -o jsonpath='{range .items[*]}{.metadata.labels.arch}{"\n"}{end}' | sort -u)

if [[ "${#targets[@]}" -eq 0 ]]; then
  warn "没有运行中的 Pod，跳过压测对比"
else
  log "三语言压测：每线程 ${BENCH_ITERATIONS} 次 SHA-256，threads = 容器可见 vCPU"
  probe_cmd=""
  for t in "${targets[@]}"; do
    IFS='|' read -r group itype ip <<<"${t}"
    # 先跑一次丢弃，排除 JIT/解释器/页缓存预热的影响
    probe_cmd+="wget -qO- 'http://${ip}:8080/api/bench?lang=all&iterations=${BENCH_ITERATIONS}' >/dev/null 2>&1; "
    probe_cmd+="printf '%s|%s|' '${group}' '${itype}'; "
    probe_cmd+="wget -qO- 'http://${ip}:8080/api/bench?lang=all&iterations=${BENCH_ITERATIONS}' | tr -d '\n '; echo; "
  done

  bench_raw="$(run_probe polyglot-bench-probe "${probe_cmd}" || true)"

  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "${bench_raw}" | python3 -c '
import json, sys

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
    for r in d.get("results", []):
        if r.get("error"):
            print("   [失败] {:<10} {:<8} {}".format(group, r.get("lang", "?"), r["error"]))
            continue
        rows.append({
            "group": group, "itype": itype, "lang": r.get("lang", "?"),
            "threads": r.get("threads", "?"), "ms": r.get("elapsedMillis", 0),
            "ops": r.get("opsPerSecond", 0), "runtime": r.get("runtime", "")[:34],
        })

if not rows:
    sys.exit("   压测结果解析失败，原始输出见上方")

print()
print("   {:<8} {:<10} {:<14} {:>7} {:>10} {:>14} {:>8}".format(
    "LANG", "GROUP", "INSTANCE-TYPE", "THREADS", "耗时(ms)", "ops/s", "相对"))
# 按语言分组：每种语言内部比较两种架构
for lang in ("go", "cpp", "python"):
    items = [r for r in rows if r["lang"] == lang]
    if not items:
        continue
    best = max(i["ops"] for i in items) or 1
    for i in sorted(items, key=lambda x: -x["ops"]):
        print("   {:<8} {:<10} {:<14} {:>7} {:>10} {:>14,} {:>7.0f}%".format(
            i["lang"], i["group"], i["itype"], i["threads"], i["ms"], i["ops"],
            i["ops"] / best * 100))
    print()
print("   同一语言的两行对比架构差异；不同语言之间只能看数量级，实现细节不同不宜直接比。")
print("   Python 的 threads>1 用多进程（GIL 限制），Go 用 goroutine，C++ 用 std::thread。")
' || printf '%s\n' "${bench_raw}"
  else
    printf '%s\n' "${bench_raw}"
  fi
fi

cat <<EOF

完成。多语言服务已部署：
  Service : polyglot-arch-demo（与 Java 服务的 java-arch-demo 相互独立）
  镜像    : ${POLYGLOT_IMAGE_URI}

本地访问：
  kubectl -n ${NAMESPACE} port-forward svc/polyglot-arch-demo 8081:80
  curl -s localhost:8081/                                  # 三种语言的运行时概览
  curl -s 'localhost:8081/api/bench?lang=all' | jq         # 三语言压测
  curl -s 'localhost:8081/api/bench?lang=cpp&threads=1'    # 单语言、单线程
EOF
