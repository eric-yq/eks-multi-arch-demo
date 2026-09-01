#!/usr/bin/env bash
# 步骤 5：验证服务在各节点组上的分布与表现
#
# 步骤 4 之后跑：只有 amd64 一组，用来展示"改造前"的现状。
# 步骤 6 之后跑：amd64 + arm64 两组，用来对比同一个镜像在 x86 与 Graviton 上的表现。
#
# 说明：Pod 上的 arch 标签是"部署分组标识"，同时也是 Deployment selector 的一部分
# （selector 创建后不可变，所以各组必须取不同的值，否则会互相抢 Pod）。
# 真实 CPU 架构以节点标签 kubernetes.io/arch 和容器内 uname -m 为准。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

need kubectl
PROBE_IMAGE="${PROBE_IMAGE:-public.ecr.aws/docker/library/alpine:3.22}"
BENCH_ITERATIONS="${BENCH_ITERATIONS:-2000000}"
APP_SELECTOR="app=java-arch-demo"

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
    log "5) 粗略 CPU 对比：${#targets[@]} 个分组，每线程 ${BENCH_ITERATIONS} 次 SHA-256（仅供参考，非正式基准测试）"
    echo "   两种口径分别测：threads=1 看单核性能，threads=<容器可见 vCPU> 看整机吞吐"

    # 在一个探针 Pod 里依次压测每个分组，输出 "分组|实例类型|口径|JSON" 便于解析。
    # 每种口径都先跑一次丢弃结果：JIT 编译只在首次调用时发生，否则"冷"的那一组会明显偏慢。
    probe_cmd=""
    for t in "${targets[@]}"; do
      IFS='|' read -r group itype ip _pod <<<"${t}"
      for mode in single multi; do
        # threads=1 走单核；threads 不传时服务端取 availableProcessors，即容器可见的全部核
        query="iterations=${BENCH_ITERATIONS}"
        [[ "${mode}" == "single" ]] && query="${query}&threads=1"
        probe_cmd+="wget -qO- 'http://${ip}:8080/api/bench?${query}' >/dev/null 2>&1; "
        probe_cmd+="printf '%s|%s|%s|' '${group}' '${itype}' '${mode}'; "
        probe_cmd+="wget -qO- 'http://${ip}:8080/api/bench?${query}' || echo '{}'; echo; "
      done
    done

    bench_raw="$(run_probe bench-probe "${probe_cmd}" || true)"

    if command -v python3 >/dev/null 2>&1; then
      printf '%s\n' "${bench_raw}" | python3 -c '
import json, sys

rows = {"single": [], "multi": []}
for line in sys.stdin:
    parts = line.strip().split("|", 3)
    if len(parts) != 4 or not parts[3].startswith("{"):
        continue
    group, itype, mode, payload = parts
    try:
        d = json.loads(payload)
    except json.JSONDecodeError:
        continue
    if "opsPerSecond" not in d or mode not in rows:
        continue
    rows[mode].append({
        "group": group,
        "itype": itype,
        "arch": d.get("osArch", "?"),
        "ms": d.get("elapsedMillis", 0),
        "ops": d.get("opsPerSecond", 0),
        "threads": d.get("threads", "?"),
        "cpus": d.get("availableProcessors", "?"),
    })

if not any(rows.values()):
    sys.exit("   压测结果解析失败，原始输出见上方")

HEAD = "   {:<11} {:<14} {:<9} {:>8} {:>10} {:>14} {:>8}"
ROW = "   {:<11} {:<14} {:<9} {:>8} {:>10} {:>14,} {:>7.0f}%"

def table(title, items, note):
    if not items:
        return
    print()
    print("   " + title)
    print(HEAD.format("GROUP", "INSTANCE-TYPE", "OS-ARCH", "THREADS", "耗时(ms)", "ops/s", "相对"))
    best = max(i["ops"] for i in items) or 1
    for i in sorted(items, key=lambda x: -x["ops"]):
        print(ROW.format(i["group"], i["itype"], i["arch"], i["threads"], i["ms"],
                         i["ops"], i["ops"] / best * 100))
    print("   " + note)

table("单核（threads=1）—— 反映单线程标量性能", rows["single"],
      "x86 单核主频高，这一口径通常 x86 领先。")
table("多核（threads = 容器可见 vCPU）—— 反映整机吞吐", rows["multi"],
      "Graviton 的 vCPU 是物理核（无 SMT），x86 的 4 vCPU 通常是 2 物理核 + 超线程。")

# 每组的多核加速比：能直观看出 SMT 与物理核的差别
single = {i["group"]: i for i in rows["single"]}
scale = [(g, m, single[g]) for g in single for m in rows["multi"] if m["group"] == g]
if scale:
    print()
    print("   多核加速比（多核 ops/s ÷ 单核 ops/s，理想值 = 线程数）")
    print("   {:<11} {:<14} {:>8} {:>12} {:>10}".format(
        "GROUP", "INSTANCE-TYPE", "THREADS", "加速比", "效率"))
    for group, multi, one in scale:
        ratio = multi["ops"] / one["ops"] if one["ops"] else 0
        threads = multi["threads"] if isinstance(multi["threads"], int) else 1
        print("   {:<11} {:<14} {:>8} {:>11.2f}x {:>9.0f}%".format(
            group, multi["itype"], multi["threads"], ratio,
            ratio / threads * 100 if threads else 0))

print()
print("   注：每种口径都先跑一轮丢弃以排除 JIT 预热；容器 limits.cpu 必须给到全部 vCPU，")
print("       否则 cgroup 配额会把多线程压回单核（各组的 limits 必须一致才有可比性）。")
' || printf '%s\n' "${bench_raw}"
    else
      printf '%s\n' "${bench_raw}"
    fi
  fi
fi

# ---------- 6) 原生依赖：lz4-java（第三方 .so）与自研 JNI 库 ----------
# 这一段是真正的断言，不只是打印：
#   - archMatchesJvm=false 说明加载到了错误架构的 .so
#   - usingNativeSo=false  说明 lz4 退回了纯 Java 实现，没走 jar 内置的 .so
#   - roundTripVerified/xxHashMatch=false 说明压缩结果不自洽
verify_failed=0

if [[ "${#targets[@]}" -eq 0 ]]; then
  warn "6) 没有运行中的 Pod，跳过原生依赖检查"
else
  thread_desc="容器可见 vCPU"
  [[ "${BENCH_THREADS:-0}" != "0" ]] && thread_desc="${BENCH_THREADS}"
  log "6) 原生依赖检查（lz4-java 第三方 .so + 自研 libarchdemo_native.so via JNI），threads = ${thread_desc}"

  # 两个接口都走多线程：每线程各跑 iterations 轮，吞吐为聚合值。
  # 不传 threads 时服务端取容器可见 vCPU 数，这样多核优势才体现得出来。
  thread_param=""
  [[ "${BENCH_THREADS:-0}" != "0" ]] && thread_param="&threads=${BENCH_THREADS}"

  probe_cmd=""
  for t in "${targets[@]}"; do
    IFS='|' read -r group itype ip _pod <<<"${t}"
    # 先各打一次丢弃：JIT 与 JNI 首次调用、原生库首次解压加载都在这一轮完成
    probe_cmd+="wget -qO- 'http://${ip}:8080/api/compress?sizeBytes=262144&iterations=10${thread_param}' >/dev/null 2>&1; "
    probe_cmd+="printf 'compress|%s|%s|' '${group}' '${itype}'; "
    probe_cmd+="wget -qO- 'http://${ip}:8080/api/compress?sizeBytes=262144&iterations=30${thread_param}' | tr -d '\n '; echo; "
    probe_cmd+="wget -qO- 'http://${ip}:8080/api/native?iterations=2000&sizeBytes=4096${thread_param}' >/dev/null 2>&1; "
    probe_cmd+="printf 'native|%s|%s|' '${group}' '${itype}'; "
    probe_cmd+="wget -qO- 'http://${ip}:8080/api/native?iterations=20000&sizeBytes=4096${thread_param}' | tr -d '\n '; echo; "
  done

  native_raw="$(run_probe native-probe "${probe_cmd}" || true)"

  if command -v python3 >/dev/null 2>&1; then
    printf '%s\n' "${native_raw}" | python3 -c '
import json, sys

compress, native = [], []
for line in sys.stdin:
    parts = line.strip().split("|", 3)
    if len(parts) != 4 or not parts[3].startswith("{"):
        continue
    kind, group, itype, payload = parts
    try:
        d = json.loads(payload)
    except json.JSONDecodeError:
        continue
    d["_group"], d["_itype"] = group, itype
    (compress if kind == "compress" else native).append(d)

failures = []

if compress:
    print()
    print("   lz4-java（jar 内置各架构 .so，代表上游已适配 aarch64 的第三方依赖）")
    print("   {:<11} {:<14} {:<22} {:>7} {:>8} {:>10} {:>12} {:>8}".format(
        "GROUP", "INSTANCE-TYPE", "IMPLEMENTATION", "原生so", "THREADS", "压缩率",
        "压缩MiB/s", "往返校验"))
    for d in compress:
        group = d["_group"]
        native_so = d.get("usingNativeSo")
        ok = d.get("roundTripVerified") and d.get("xxHashMatch")
        print("   {:<11} {:<14} {:<22} {:>7} {:>8} {:>10} {:>12} {:>8}".format(
            group, d["_itype"], str(d.get("implementation"))[:22],
            "yes" if native_so else "NO", d.get("threads", "?"),
            d.get("compressionRatio", "?"), d.get("compressMiBPerSecond", "?"),
            "ok" if ok else "FAIL"))
        if not native_so:
            failures.append(group + ": lz4 未使用原生 .so（退回纯 Java）")
        if not ok:
            failures.append(group + ": lz4 往返校验或 xxHash 不一致")

if native:
    print()
    print("   自研 libarchdemo_native.so（纯标量 C，无 SIMD，经 JNI 调用）")
    print("   {:<11} {:<14} {:>7} {:>10} {:>10} {:>8} {:>12} {:>12}".format(
        "GROUP", "INSTANCE-TYPE", "可用", "so架构", "架构匹配", "THREADS",
        "crc32MiB/s", "fnv1aMiB/s"))
    for d in native:
        group = d["_group"]
        avail = d.get("available")
        match = d.get("archMatchesJvm")
        crc = (d.get("crc32") or {}).get("miBPerSecond", "?")
        fnv = (d.get("fnv1a64") or {}).get("miBPerSecond", "?")
        print("   {:<11} {:<14} {:>7} {:>10} {:>10} {:>8} {:>12} {:>12}".format(
            group, d["_itype"], "yes" if avail else "NO",
            str(d.get("nativeArch", "-")), "ok" if match else "MISMATCH",
            d.get("threads", "?"), crc, fnv))
        if not avail:
            failures.append(group + ": JNI 库未加载（" + str(d.get("loadError", "未知原因")) + "）")
        elif not match:
            failures.append(group + ": .so 架构(" + str(d.get("nativeArch")) + ") 与 JVM 架构不一致")

print()
if failures:
    print("   [FAIL] 原生依赖检查未通过：")
    for item in failures:
        print("          - " + item)
    sys.exit(1)
print("   [ok] 两种架构都加载了匹配自身架构的原生库，压缩往返校验通过。")
print("   要点：lz4-java 由上游打包好 aarch64，自研 .so 需要自己在构建镜像时按架构编译。")
print("   吞吐均为多线程聚合值（每线程各跑 iterations 轮），压缩与解压分两个并行阶段各自计时；")
print("   想看单核口径：BENCH_THREADS=1 ./scripts/05-verify.sh")
' || verify_failed=1
  else
    printf '%s\n' "${native_raw}"
  fi
fi

log "本地访问服务：kubectl -n ${NAMESPACE} port-forward svc/java-arch-demo 8080:80  然后打开 http://localhost:8080/"

if [[ "${verify_failed}" -ne 0 ]]; then
  die "原生依赖检查未通过，详见上面的 [FAIL] 列表"
fi
