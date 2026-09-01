#!/usr/bin/env bash
# 步骤 9：多语言服务的验证与压测对比（对应 Java 服务的 05-verify.sh）。
#
# 自动发现已部署的架构分组，用同一个负载（SHA-256 循环）横向对比
# 三种语言 × 各架构。只部署了一侧时也能跑，只是表里只有一行。
#
# 可调：BENCH_ITERATIONS（每线程迭代数，默认 2000000）
#       BENCH_THREADS（0/留空 = 容器可见 vCPU；设 1 则测单核）
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need kubectl
APP_SELECTOR="app=polyglot-arch-demo"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-2000000}"
BENCH_THREADS="${BENCH_THREADS:-0}"
PROBE_IMAGE="${PROBE_IMAGE:-public.ecr.aws/docker/library/alpine:3.22}"

log "1) 节点架构与实例类型"
kubectl get nodes \
  -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup

declare -A NODE_TYPE
while read -r n t; do
  [[ -n "${n:-}" ]] && NODE_TYPE["${n}"]="${t}"
done < <(kubectl get nodes --no-headers -o custom-columns='\
N:.metadata.name,T:.metadata.labels.node\.kubernetes\.io/instance-type')

log "2) 多语言服务的 Pod 落点"
kubectl -n "${NAMESPACE}" get pods -o wide -l "${APP_SELECTOR}" -L arch

log "3) 各 Pod 内三种语言的运行时版本"
for pod in $(kubectl -n "${NAMESPACE}" get pods -l "${APP_SELECTOR}" -o name); do
  node="$(kubectl -n "${NAMESPACE}" get "${pod}" -o jsonpath='{.spec.nodeName}')"
  printf '   %s  (%s / %s)\n' "${pod#pod/}" "${node}" "${NODE_TYPE[${node}]:-?}"
  kubectl -n "${NAMESPACE}" exec "${pod}" -- sh -c '
    printf "      uname -m : %s\n" "$(uname -m)"
    printf "      C++      : %s\n" "$(/app/bench-cpp --version)"
    printf "      Python   : %s\n" "$(python3 /app/bench.py --version)"
  ' 2>/dev/null || warn "读取 ${pod} 运行时信息失败"
done

log "4) 通过 Service 访问 8 次，统计返回的架构分布"
run_probe polyglot-arch-probe '
for i in $(seq 1 8); do
  wget -qO- http://polyglot-arch-demo/api/info \
    | grep -o "\"osArch\": \"[^\"]*\"" | head -1
done | sort | uniq -c | sed "s/^/   /"' \
  || warn "Service 采样失败"

# ---------- 5) 三语言 × 各架构 压测对比 ----------
targets=()
while read -r group; do
  [[ -n "${group:-}" ]] || continue
  read -r pod ip node < <(kubectl -n "${NAMESPACE}" \
    get pods -l "${APP_SELECTOR},arch=${group}" \
    --field-selector status.phase=Running --no-headers \
    -o custom-columns='P:.metadata.name,I:.status.podIP,N:.spec.nodeName' | head -1)
  [[ -n "${ip:-}" ]] || continue
  targets+=("${group}|${NODE_TYPE[${node}]:-?}|${ip}")
done < <(kubectl -n "${NAMESPACE}" get pods -l "${APP_SELECTOR}" \
  -o jsonpath='{range .items[*]}{.metadata.labels.arch}{"\n"}{end}' | sort -u)

if [[ "${#targets[@]}" -eq 0 ]]; then
  warn "5) 没有运行中的 Pod，跳过压测对比"
else
  thread_desc="容器可见 vCPU"
  [[ "${BENCH_THREADS}" != "0" ]] && thread_desc="${BENCH_THREADS}"
  log "5) 三语言压测：${#targets[@]} 个分组，每线程 ${BENCH_ITERATIONS} 次 SHA-256，threads = ${thread_desc}"

  query="lang=all&iterations=${BENCH_ITERATIONS}"
  [[ "${BENCH_THREADS}" != "0" ]] && query="${query}&threads=${BENCH_THREADS}"

  probe_cmd=""
  for t in "${targets[@]}"; do
    IFS='|' read -r group itype ip <<<"${t}"
    # 先跑一次丢弃：排除 JIT / 解释器 / 页缓存预热的影响
    probe_cmd+="wget -qO- 'http://${ip}:8080/api/bench?${query}' >/dev/null 2>&1; "
    probe_cmd+="printf '%s|%s|' '${group}' '${itype}'; "
    probe_cmd+="wget -qO- 'http://${ip}:8080/api/bench?${query}' | tr -d '\n '; echo; "
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
            "ops": r.get("opsPerSecond", 0), "spawn": r.get("spawnMillis", 0),
        })

if not rows:
    sys.exit("   压测结果解析失败，原始输出见上方")

HEAD = "   {:<8} {:<10} {:<14} {:>7} {:>10} {:>14} {:>8} {:>10}"
ROW = "   {:<8} {:<10} {:<14} {:>7} {:>10} {:>14,} {:>7.0f}% {:>10}"
print()
print(HEAD.format("LANG", "GROUP", "INSTANCE-TYPE", "THREADS", "耗时(ms)",
                  "ops/s", "相对", "子进程(ms)"))
for lang in ("go", "cpp", "python"):
    items = [r for r in rows if r["lang"] == lang]
    if not items:
        continue
    best = max(i["ops"] for i in items) or 1
    for i in sorted(items, key=lambda x: -x["ops"]):
        print(ROW.format(i["lang"], i["group"], i["itype"], i["threads"], i["ms"],
                         i["ops"], i["ops"] / best * 100,
                         i["spawn"] if i["spawn"] else "-"))
    print()
print("   同一语言的两行对比架构差异；不同语言之间只看数量级，实现细节不同不宜直接比。")
print("   子进程列是 Python / C++ 的进程启动开销，未计入耗时（Go 在本进程内跑）。")
print("   Python 的 threads>1 用多进程（GIL 限制），Go 用 goroutine，C++ 用 std::thread。")
' || printf '%s\n' "${bench_raw}"
  else
    printf '%s\n' "${bench_raw}"
  fi
fi

# ---------- 6) CGO 原生库 + C++ SIMD 分支 ----------
# 断言项：
#   - archMatchesGo=false 说明 CGO 链接到了错误架构的 .so
#   - resultsMatch=false  说明 SIMD 分支与标量参考实现结果不一致（最严重）
#   - 两种架构的 simdPath 必须不同，否则说明预编译宏没有按架构分支
verify_failed=0

if [[ "${#targets[@]}" -eq 0 ]]; then
  warn "6) 没有运行中的 Pod，跳过原生库与 SIMD 检查"
else
  log "6) CGO 自研库（libgodemo_native.so）与 C++ SIMD 分支检查"

  probe_cmd=""
  for t in "${targets[@]}"; do
    IFS='|' read -r group itype ip <<<"${t}"
    probe_cmd+="printf 'cgo|%s|%s|' '${group}' '${itype}'; "
    probe_cmd+="wget -qO- 'http://${ip}:8080/api/native?iterations=20000&sizeBytes=4096' | tr -d '\n '; echo; "
    probe_cmd+="printf 'simd|%s|%s|' '${group}' '${itype}'; "
    probe_cmd+="wget -qO- 'http://${ip}:8080/api/simd?bytes=1048576&iterations=200' | tr -d '\n '; echo; "
  done

  native_raw="$(run_probe polyglot-native-probe "${probe_cmd}" || true)"

  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "${native_raw}" | python3 -c '
import json, sys

cgo, simd = [], []
for line in sys.stdin:
    parts = line.strip().split("|", 3)
    if len(parts) != 4 or not parts[3].startswith("{"):
        continue
    kind, group, itype, payload = parts
    try:
        d = json.loads(payload)
    except json.JSONDecodeError:
        continue
    if kind == "simd":
        # Go 前门把 C++ 的输出包在 result 里，顶层另有 compiledSimdPath / osArch
        inner = d.get("result") or {}
        merged = dict(inner)
        merged.setdefault("simdPath", d.get("compiledSimdPath"))
        merged["_error"] = d.get("error")
        d = merged
    d["_group"], d["_itype"] = group, itype
    (cgo if kind == "cgo" else simd).append(d)

failures = []

if cgo:
    print()
    print("   CGO 调用自研 C 库（纯标量，无 SIMD，按架构分别编译）")
    print("   {:<11} {:<14} {:>7} {:>10} {:>10} {:<32}".format(
        "GROUP", "INSTANCE-TYPE", "CGO", "so架构", "架构匹配", "NATIVE-INFO"))
    for d in cgo:
        group = d["_group"]
        match = d.get("archMatchesGo")
        print("   {:<11} {:<14} {:>7} {:>10} {:>10} {:<32}".format(
            group, d["_itype"], "on" if d.get("cgoEnabled") else "OFF",
            str(d.get("nativeArch", "-")), "ok" if match else "MISMATCH",
            str(d.get("nativeInfo", ""))[:32]))
        if not d.get("cgoEnabled"):
            failures.append(group + ": CGO 未启用")
        elif not match:
            failures.append(group + ": .so 架构(" + str(d.get("nativeArch")) + ") 与 goArch 不一致")

if simd:
    print()
    print("   C++ SIMD：同一份源码用预编译宏按架构分支，与标量实现对比")
    print("   {:<11} {:<14} {:<22} {:>10} {:>10} {:>8} {:>8}".format(
        "GROUP", "INSTANCE-TYPE", "SIMD-PATH", "SIMD GiB/s", "标量 GiB/s",
        "加速比", "结果一致"))
    for d in simd:
        group = d["_group"]
        if d.get("_error"):
            print("   [失败] {:<10} SIMD 接口报错：{}".format(group, d["_error"]))
            failures.append(group + ": SIMD 接口报错 " + str(d["_error"]))
            continue
        matches = d.get("resultsMatch")
        print("   {:<11} {:<14} {:<22} {:>10} {:>10} {:>7}x {:>8}".format(
            group, d["_itype"], str(d.get("simdPath", "?"))[:22],
            d.get("simdGiBPerSecond", "?"), d.get("scalarGiBPerSecond", "?"),
            d.get("speedup", "?"), "ok" if matches else "MISMATCH"))
        if not matches:
            failures.append(group + ": SIMD 结果与标量参考实现不一致")

    paths = {d["_group"]: d.get("simdPath") for d in simd if not d.get("_error")}
    if len(paths) > 1 and len(set(paths.values())) == 1:
        failures.append("两种架构的 simdPath 相同(" + str(list(paths.values())[0]) +
                        ")，预编译宏没有按架构分支")

print()
if failures:
    print("   [FAIL] 原生库 / SIMD 检查未通过：")
    for item in failures:
        print("          - " + item)
    sys.exit(1)
print("   [ok] CGO 库架构匹配，SIMD 与标量结果一致。")
print("   要点：x86 走 SSE2/AVX2、arm64 走 NEON，是同一份 .cpp 由预编译宏分支出来的，")
print("         两边算出的结果必须完全一致——这正是 SIMD 迁移要验证的核心。")
' || verify_failed=1
  else
    printf '%s\n' "${native_raw}"
  fi
fi

cat <<EOF

只测单核（对比单线程标量性能）：
  BENCH_THREADS=1 ./scripts/09-verify-polyglot.sh

本地访问：
  kubectl -n ${NAMESPACE} port-forward svc/polyglot-arch-demo 8081:80
  curl -s 'localhost:8081/api/native' | jq   # CGO 自研库
  curl -s 'localhost:8081/api/simd'   | jq   # SIMD 分支与标量对比
EOF

if [[ "${verify_failed}" -ne 0 ]]; then
  die "原生库 / SIMD 检查未通过，详见上面的 [FAIL] 列表"
fi
