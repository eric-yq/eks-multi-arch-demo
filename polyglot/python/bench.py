#!/usr/bin/env python3
"""Python 侧压测：与 Go / C++ / Java 版本跑完全相同的 SHA-256 负载。

由 Go 前门以子进程方式调用，自己计时并把 JSON 打到 stdout，
所以解释器启动开销不会算进 elapsedMillis（Go 侧会单独报 spawnMillis）。

关于并发：CPython 有 GIL，纯计算用线程无法利用多核，
因此 threads > 1 时用 multiprocessing 起多个进程。这一点是 Python 服务
上多核机器（尤其是核数更多的 Graviton 实例）时最容易踩的坑。
"""

from __future__ import annotations

import argparse
import hashlib
import json
import multiprocessing as mp
import platform
import ssl
import sys
import time

PAYLOAD = b"eks-multi-arch-demo-payload"
MAX_ITERATIONS = 20_000_000
MAX_THREADS = 64
WARMUP_CAP = 50_000


def sha256_loop(iterations: int) -> int:
    """每次迭代：sha256(PAYLOAD + byte(i & 0xFF))，累加哈希首尾字节。"""
    checksum = 0
    payload = PAYLOAD
    new = hashlib.sha256
    for i in range(iterations):
        digest = new(payload + bytes((i & 0xFF,))).digest()
        checksum += digest[0] + digest[-1]
    return checksum


def run_parallel(workers: int, iterations: int) -> list[int]:
    if workers == 1:
        return [sha256_loop(iterations)]
    # 用进程绕开 GIL；fork 在 Linux 上最省事，子进程直接继承代码
    ctx = mp.get_context("fork")
    with ctx.Pool(processes=workers) as pool:
        return pool.map(sha256_loop, [iterations] * workers)


def runtime_version() -> str:
    impl = platform.python_implementation()
    return (f"{impl} {platform.python_version()} "
            f"({ssl.OPENSSL_VERSION.split(' ')[0]} {ssl.OPENSSL_VERSION.split(' ')[1]}, "
            f"{platform.machine()})")


def main() -> int:
    parser = argparse.ArgumentParser(description="SHA-256 CPU 压测（Python）")
    parser.add_argument("--iterations", type=int, default=2_000_000, help="每个 worker 的迭代次数")
    parser.add_argument("--threads", type=int, default=1, help="并发 worker 数（用进程实现）")
    parser.add_argument("--version", action="store_true", help="只打印运行时版本")
    args = parser.parse_args()

    if args.version:
        print(runtime_version())
        return 0

    if not 1 <= args.iterations <= MAX_ITERATIONS:
        print(json.dumps({"error": f"iterations 必须在 1 和 {MAX_ITERATIONS} 之间"}))
        return 2
    if not 1 <= args.threads <= MAX_THREADS:
        print(json.dumps({"error": f"threads 必须在 1 和 {MAX_THREADS} 之间"}))
        return 2

    # 预热：让解释器完成 import/字节码准备，与其他语言口径一致
    run_parallel(args.threads, min(args.iterations, WARMUP_CAP))

    start = time.perf_counter()
    checksums = run_parallel(args.threads, args.iterations)
    elapsed = time.perf_counter() - start

    total = args.iterations * args.threads
    aggregate = int(total / elapsed) if elapsed > 0 else 0

    print(json.dumps({
        "lang": "python",
        "runtime": runtime_version(),
        "mode": "single-thread" if args.threads == 1 else "multi-process",
        "threads": args.threads,
        "iterationsPerThread": args.iterations,
        "totalIterations": total,
        "elapsedMillis": round(elapsed * 1000, 2),
        "opsPerSecond": aggregate,
        "opsPerSecondPerThread": aggregate // args.threads if args.threads else 0,
        "checksum": sum(checksums),
        "note": ("GIL 限制：纯计算用线程无法并行，threads>1 时改用 multiprocessing 进程池"
                 if args.threads > 1 else "单进程单线程"),
    }))
    return 0


if __name__ == "__main__":
    sys.exit(main())
