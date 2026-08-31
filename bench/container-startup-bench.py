#!/usr/bin/env python3
"""
在单台实例上批量启动容器，测量启动耗时并输出统计报告（min / avg / p50 / p90 / p95 / p99 / max）。

只依赖 docker CLI 与 Python 3 标准库，与本仓库其他脚本互不影响。

测量的三个阶段
--------------
1. docker run 返回     ：`docker run -d` 命令本身的耗时（daemon 创建 + 启动容器的调用延迟）
2. 应用就绪（累计）    ：从发起 docker run 到就绪探测通过的总耗时（含 1）；JVM 冷启动主要体现在这里
3. docker 自报启动     ：容器 State.StartedAt - Created，纯 daemon/runtime 侧开销，用于交叉验证

典型用法
--------
# 1) 最小验证：8 个 alpine，不做就绪探测
./bench/container-startup-bench.py --image public.ecr.aws/docker/library/alpine:3.22 \
    --count 8 -- sleep 60

# 2) 本仓库的 Java 服务：50 个容器，等 actuator readiness 返回 2xx
./bench/container-startup-bench.py \
    --image <account>.dkr.ecr.<region>.amazonaws.com/java-arch-demo:1.0.0 \
    --count 50 --memory 512m --cpus 1 \
    --ready http --ready-port 8080 --ready-path /actuator/health/readiness \
    --json /tmp/startup.json --csv /tmp/startup.csv

# 3) 并发启动，测密度/争抢下的启动表现（容器全部保留到结束）
./bench/container-startup-bench.py --image ... --count 50 --concurrency 10 --cleanup end

# 在 x86 与 Graviton 实例上分别跑同一条命令，即可对比同一个多架构镜像的启动耗时。

注意
----
* 就绪探测走容器在 bridge 网络上的 IP，不发布端口，所以启动几十个容器不会有端口冲突。
* 默认每测完一个就删掉容器（--cleanup each），避免 50 个 JVM 把内存吃满；
  想测"同时跑 N 个"的场景用 --cleanup end。
* 启动 JVM 类镜像务必给 --memory：否则每个 JVM 都按宿主机内存算堆上限，容器一多必然 OOM。
* 脚本只会删除自己创建的容器（带 label cstart-bench=1 且名字匹配 --name-prefix）。
"""

from __future__ import annotations

import argparse
import csv
import json
import os
import re
import signal
import socket
import statistics
import subprocess
import sys
import threading
import time
import unicodedata
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import asdict, dataclass
from datetime import datetime, timezone

LABEL_KEY = "cstart-bench"
LABEL_VALUE = "1"


# --------------------------------------------------------------------------- #
# 小工具
# --------------------------------------------------------------------------- #
def sh(cmd: list[str], timeout: float | None = 120) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)


def sh_ok(cmd: list[str], timeout: float | None = 120) -> str:
    proc = sh(cmd, timeout=timeout)
    if proc.returncode != 0:
        raise RuntimeError(f"命令失败: {' '.join(cmd)}\n{proc.stderr.strip()}")
    return proc.stdout.strip()


def display_width(text: str) -> int:
    """中日韩字符在终端里占两列，用于对齐表格。"""
    return sum(2 if unicodedata.east_asian_width(ch) in "WF" else 1 for ch in text)


def pad(text: str, width: int, align: str = "<") -> str:
    fill = " " * max(0, width - display_width(text))
    return text + fill if align == "<" else fill + text


def center(text: str, width: int) -> str:
    fill = max(0, width - display_width(text))
    left = fill // 2
    return " " * left + text + " " * (fill - left)


def human_bytes(n: float) -> str:
    for unit in ("B", "KiB", "MiB", "GiB", "TiB"):
        if abs(n) < 1024 or unit == "TiB":
            return f"{n:.1f} {unit}"
        n /= 1024
    return f"{n:.1f} TiB"


def percentile(sorted_values: list[float], q: float) -> float:
    """线性插值百分位（与 numpy.percentile 默认一致）。q 取 0~100。"""
    if not sorted_values:
        return float("nan")
    if len(sorted_values) == 1:
        return sorted_values[0]
    pos = (len(sorted_values) - 1) * q / 100.0
    low = int(pos)
    high = min(low + 1, len(sorted_values) - 1)
    frac = pos - low
    return sorted_values[low] * (1 - frac) + sorted_values[high] * frac


def summarize(values: list[float]) -> dict | None:
    vals = sorted(v for v in values if v is not None)
    if not vals:
        return None
    return {
        "n": len(vals),
        "min": vals[0],
        "p50": percentile(vals, 50),
        "avg": statistics.fmean(vals),
        "p90": percentile(vals, 90),
        "p95": percentile(vals, 95),
        "p99": percentile(vals, 99),
        "max": vals[-1],
        "stddev": statistics.stdev(vals) if len(vals) > 1 else 0.0,
    }


# --------------------------------------------------------------------------- #
# 环境信息
# --------------------------------------------------------------------------- #
def imds(path: str) -> str | None:
    """尽力读取 IMDSv2；不在 EC2 上或被禁用时返回 None。"""
    try:
        req = urllib.request.Request(
            "http://169.254.169.254/latest/api/token",
            method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"},
        )
        with urllib.request.urlopen(req, timeout=1) as resp:
            token = resp.read().decode()
        req = urllib.request.Request(
            f"http://169.254.169.254/latest/meta-data/{path}",
            headers={"X-aws-ec2-metadata-token": token},
        )
        with urllib.request.urlopen(req, timeout=1) as resp:
            return resp.read().decode().strip()
    except Exception:
        return None


def host_info() -> dict:
    info = {
        "hostname": socket.gethostname(),
        "arch": os.uname().machine,
        "kernel": f"{os.uname().sysname} {os.uname().release}",
        "vcpu": os.cpu_count(),
        "mem_total_bytes": None,
        "docker_version": None,
        "instance_type": imds("instance-type"),
        "availability_zone": imds("placement/availability-zone"),
    }
    try:
        with open("/proc/meminfo") as fh:
            for line in fh:
                if line.startswith("MemTotal:"):
                    info["mem_total_bytes"] = int(line.split()[1]) * 1024
                    break
    except OSError:
        pass
    proc = sh(["docker", "version", "--format", "{{.Server.Version}}"], timeout=30)
    if proc.returncode == 0:
        info["docker_version"] = proc.stdout.strip()
    return info


def image_info(image: str) -> dict:
    raw = sh_ok(["docker", "image", "inspect", image])
    data = json.loads(raw)[0]
    return {
        "ref": image,
        "id": data.get("Id", ""),
        "os": data.get("Os", ""),
        "architecture": data.get("Architecture", ""),
        "variant": data.get("Variant") or "",
        "size_bytes": data.get("Size"),
        "repo_digests": data.get("RepoDigests") or [],
    }


# --------------------------------------------------------------------------- #
# 单个容器的测量
# --------------------------------------------------------------------------- #
@dataclass
class Sample:
    index: int
    name: str
    warmup: bool = False
    container_id: str = ""
    cli_start_ms: float | None = None    # docker run -d 返回耗时
    ready_ms: float | None = None        # 从发起 docker run 到就绪（累计）
    wait_ms: float | None = None         # ready_ms - cli_start_ms
    daemon_ms: float | None = None       # State.StartedAt - Created
    ok: bool = True
    skipped: bool = False                # 触发 fail-fast 后未执行
    error: str = ""


def container_ip(cid: str) -> str | None:
    """取容器在 bridge 网络上的 IP。

    这里解析 NetworkSettings 的 JSON，而不是用 `-f {{.NetworkSettings.IPAddress}}`：
    Docker 29 已经去掉了顶层的 IPAddress 字段，那种写法会直接报模板错误。
    """
    proc = sh(["docker", "inspect", "-f", "{{json .NetworkSettings}}", cid], timeout=30)
    if proc.returncode != 0 or not proc.stdout.strip():
        return None
    try:
        net = json.loads(proc.stdout)
    except json.JSONDecodeError:
        return None
    if net.get("IPAddress"):                      # 老版本 docker
        return net["IPAddress"]
    for cfg in (net.get("Networks") or {}).values():   # docker 29+
        if cfg.get("IPAddress"):
            return cfg["IPAddress"]
    return None


def parse_docker_time(value: str) -> float | None:
    """解析 docker 的 RFC3339 时间戳（纳秒精度）为 epoch 秒。"""
    if not value or value.startswith("0001-01-01"):
        return None
    match = re.match(r"(.+?)(?:\.(\d+))?(Z|[+-]\d{2}:\d{2})$", value)
    if not match:
        return None
    base, frac, tz = match.groups()
    tz = "+00:00" if tz == "Z" else tz
    try:
        stamp = datetime.fromisoformat(f"{base}{tz}").timestamp()
    except ValueError:
        return None
    if frac:
        stamp += int(frac[:9].ljust(9, "0")) / 1e9
    return stamp


def daemon_start_ms(cid: str) -> float | None:
    proc = sh(["docker", "inspect", "-f", "{{.Created}}|{{.State.StartedAt}}", cid], timeout=30)
    if proc.returncode != 0 or "|" not in proc.stdout:
        return None
    created, started = proc.stdout.strip().split("|", 1)
    t_created, t_started = parse_docker_time(created), parse_docker_time(started)
    if t_created is None or t_started is None:
        return None
    return max(0.0, (t_started - t_created) * 1000.0)


def wait_ready(args, cid: str, deadline: float) -> tuple[bool, str]:
    """按 --ready 模式轮询直到就绪或超时。"""
    if args.ready == "none":
        return True, ""

    if args.ready == "log":
        pattern = re.compile(args.ready_log_pattern)
        while time.monotonic() < deadline:
            proc = sh(["docker", "logs", cid], timeout=30)
            if pattern.search(proc.stdout) or pattern.search(proc.stderr):
                return True, ""
            if not container_running(cid):
                return False, "容器在就绪前退出"
            time.sleep(max(args.poll_interval, 0.1))
        return False, f"等待日志匹配超时（{args.ready_timeout}s）"

    # 拿 IP 用单独的、更短的超时：网络模式不对时快速失败，不必耗掉整个就绪超时
    ip = None
    ip_deadline = min(deadline, time.monotonic() + args.ip_timeout)
    while time.monotonic() < ip_deadline and not ip:
        ip = container_ip(cid)
        if not ip:
            if not container_running(cid):
                return False, "容器在拿到 IP 前退出"
            time.sleep(args.poll_interval)
    if not ip:
        return False, (f"{args.ip_timeout:.0f}s 内拿不到容器 IP"
                       "（host/none 网络或自定义网络请改用 --ready log/tcp，或用 --docker-arg 指定网络）")

    url = f"http://{ip}:{args.ready_port}{args.ready_path}"
    last = ""
    while time.monotonic() < deadline:
        try:
            if args.ready == "tcp":
                with socket.create_connection((ip, args.ready_port), timeout=1):
                    return True, ""
            else:
                with urllib.request.urlopen(url, timeout=2) as resp:
                    if 200 <= resp.status < 300:
                        return True, ""
                    last = f"HTTP {resp.status}"
        except urllib.error.HTTPError as exc:
            last = f"HTTP {exc.code}"
        except Exception as exc:
            last = type(exc).__name__
        if not container_running(cid):
            return False, f"容器在就绪前退出（最后状态：{last or 'n/a'}）"
        time.sleep(args.poll_interval)
    return False, f"就绪探测超时（{args.ready_timeout}s，最后状态：{last or 'n/a'}）"


def container_running(cid: str) -> bool:
    proc = sh(["docker", "inspect", "-f", "{{.State.Running}}", cid], timeout=30)
    return proc.returncode == 0 and proc.stdout.strip() == "true"


def build_run_cmd(args, name: str) -> list[str]:
    cmd = ["docker", "run", "-d", "--name", name, "--label", f"{LABEL_KEY}={LABEL_VALUE}"]
    if args.memory:
        cmd += ["--memory", args.memory]
    if args.cpus:
        cmd += ["--cpus", str(args.cpus)]
    if args.platform:
        cmd += ["--platform", args.platform]
    for env in args.env:
        cmd += ["-e", env]
    for extra in args.docker_arg:
        cmd += extra.split()
    cmd.append(args.image)
    cmd += args.cmd
    return cmd


def measure_one(args, index: int, warmup: bool = False) -> Sample:
    name = f"{args.name_prefix}-{index:04d}"
    sample = Sample(index=index, name=name, warmup=warmup)
    cmd = build_run_cmd(args, name)

    t0 = time.perf_counter()
    proc = sh(cmd, timeout=args.ready_timeout + 60)
    t1 = time.perf_counter()

    if proc.returncode != 0:
        sample.ok = False
        sample.error = f"docker run 失败：{proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else '未知错误'}"
        return sample

    sample.container_id = proc.stdout.strip()
    sample.cli_start_ms = (t1 - t0) * 1000.0

    ok, err = wait_ready(args, sample.container_id, deadline=t1 + args.ready_timeout)
    t2 = time.perf_counter()
    if ok:
        if args.ready != "none":
            sample.ready_ms = (t2 - t0) * 1000.0
            sample.wait_ms = sample.ready_ms - sample.cli_start_ms
    else:
        sample.ok = False
        sample.error = err

    sample.daemon_ms = daemon_start_ms(sample.container_id)

    if args.cleanup == "each":
        sh(["docker", "rm", "-f", sample.container_id], timeout=120)
    return sample


# --------------------------------------------------------------------------- #
# 清理
# --------------------------------------------------------------------------- #
def cleanup(prefix: str, quiet: bool = False) -> int:
    proc = sh(
        ["docker", "ps", "-aq", "--filter", f"label={LABEL_KEY}={LABEL_VALUE}",
         "--filter", f"name=^{prefix}-"],
        timeout=60,
    )
    ids = [line for line in proc.stdout.split() if line]
    if not ids:
        return 0
    for i in range(0, len(ids), 50):
        sh(["docker", "rm", "-f", *ids[i:i + 50]], timeout=300)
    if not quiet:
        print(f"已清理 {len(ids)} 个测试容器", file=sys.stderr)
    return len(ids)


# --------------------------------------------------------------------------- #
# 报告
# --------------------------------------------------------------------------- #
def render_report(args, host: dict, image: dict, samples: list[Sample],
                  started_at: datetime, wall_seconds: float, note: str = "") -> str:
    measured = [s for s in samples if not s.warmup]
    ok = [s for s in measured if s.ok]
    failed = [s for s in measured if not s.ok and not s.skipped]
    skipped = [s for s in measured if s.skipped]
    executed = len(ok) + len(failed)

    phases = [
        ("docker run 返回 (ms)", [s.cli_start_ms for s in ok]),
        ("应用就绪 累计 (ms)", [s.ready_ms for s in ok]),
        ("  其中等待就绪 (ms)", [s.wait_ms for s in ok]),
        ("docker 自报启动 (ms)", [s.daemon_ms for s in ok]),
    ]

    mem = human_bytes(host["mem_total_bytes"]) if host["mem_total_bytes"] else "?"
    width = 100
    lines = ["=" * width, center("容器启动耗时报告", width), "=" * width]

    lines.append(f"主机        : {host['hostname']}  ({host['arch']}, {host['vcpu']} vCPU, {mem}, {host['kernel']})")
    if host["instance_type"]:
        lines.append(f"实例        : {host['instance_type']}  {host['availability_zone'] or ''}".rstrip())
    lines.append(f"Docker      : {host['docker_version'] or '?'}")

    digest = image["repo_digests"][0].split("@")[-1] if image["repo_digests"] else image["id"]
    platform = "/".join(x for x in (image["os"], image["architecture"], image["variant"]) if x)
    size = human_bytes(image["size_bytes"]) if image["size_bytes"] else "?"
    lines.append(f"镜像        : {image['ref']}")
    lines.append(f"              {platform}  {digest[:26]}...  解压后 {size}")

    ready_desc = {
        "none": "无（只测 docker run 返回）",
        "tcp": f"tcp {args.ready_port}",
        "http": f"http {args.ready_path}:{args.ready_port}",
        "log": f"log /{args.ready_log_pattern}/",
    }[args.ready]
    lines.append(
        f"参数        : 数量 {args.count}  并发 {args.concurrency}  "
        f"内存上限 {args.memory or '无'}  CPU 上限 {args.cpus or '无'}  就绪探测 {ready_desc}"
    )
    lines.append(
        f"              预热 {args.warmup}（不计入统计）  容器回收 {args.cleanup}  "
        f"轮询间隔 {int(args.poll_interval * 1000)}ms"
    )
    lines.append(
        f"时间        : {started_at.astimezone().strftime('%Y-%m-%d %H:%M:%S %Z')}  "
        f"总耗时 {wall_seconds:.1f}s  吞吐 {executed / wall_seconds:.2f} 容器/秒"
    )
    sample_line = f"样本        : 成功 {len(ok)} / 失败 {len(failed)}"
    if skipped:
        sample_line += f" / 未执行 {len(skipped)}"
    sample_line += f"（计划 {args.count}，另有 {args.warmup} 个预热）"
    lines.append(sample_line)
    if note:
        lines.append(f"提示        : {note}")
    lines.append("-" * width)

    label_width = 26
    lines.append(
        pad("阶段", label_width)
        + f"{'n':>5}{'min':>10}{'p50':>10}{'avg':>10}{'p90':>10}{'p95':>10}{'p99':>10}{'max':>10}{'stddev':>10}"
    )
    any_row = False
    for label, values in phases:
        st = summarize(values)
        if not st:
            continue
        any_row = True
        lines.append(
            pad(label, label_width)
            + f"{st['n']:>5}"
            + f"{st['min']:>10.1f}{st['p50']:>10.1f}{st['avg']:>10.1f}"
            + f"{st['p90']:>10.1f}{st['p95']:>10.1f}{st['p99']:>10.1f}{st['max']:>10.1f}{st['stddev']:>10.1f}"
        )
    if not any_row:
        lines.append("（没有成功的样本）")
    lines.append("-" * width)

    if failed:
        lines.append(f"失败样本（最多列出 5 个，共 {len(failed)} 个）：")
        for s in failed[:5]:
            lines.append(f"  {s.name}: {s.error}")
        lines.append("-" * width)

    lines.append("百分位算法：线性插值（同 numpy.percentile 默认）。")
    if args.ready != "none":
        lines.append("「应用就绪 累计」= docker run 发起 → 就绪探测通过，是端到端的可用耗时；")
        lines.append("「docker 自报启动」只含 daemon/runtime 开销，不含应用自身初始化。")
    lines.append("=" * width)
    return "\n".join(lines)


def write_json(path: str, args, host: dict, image: dict, samples: list[Sample],
               started_at: datetime, wall_seconds: float) -> None:
    ok = [s for s in samples if s.ok and not s.warmup]
    payload = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "started_at": started_at.isoformat(),
        "wall_seconds": wall_seconds,
        "host": host,
        "image": image,
        "params": {
            "count": args.count, "concurrency": args.concurrency, "warmup": args.warmup,
            "memory": args.memory, "cpus": args.cpus, "ready": args.ready,
            "ready_port": args.ready_port, "ready_path": args.ready_path,
            "ready_timeout": args.ready_timeout, "cleanup": args.cleanup,
            "command": args.cmd,
        },
        "stats": {
            "cli_start_ms": summarize([s.cli_start_ms for s in ok]),
            "ready_ms": summarize([s.ready_ms for s in ok]),
            "wait_ms": summarize([s.wait_ms for s in ok]),
            "daemon_ms": summarize([s.daemon_ms for s in ok]),
        },
        "samples": [asdict(s) for s in samples],
    }
    with open(path, "w") as fh:
        json.dump(payload, fh, indent=2, ensure_ascii=False)


def write_csv(path: str, samples: list[Sample]) -> None:
    fields = ["index", "name", "warmup", "ok", "cli_start_ms", "ready_ms",
              "wait_ms", "daemon_ms", "container_id", "error"]
    with open(path, "w", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields)
        writer.writeheader()
        for s in samples:
            row = asdict(s)
            writer.writerow({k: row.get(k) for k in fields})


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="批量启动容器并统计启动耗时（min/avg/p50/p90/p95/p99/max）",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="容器启动命令写在 -- 之后，例如：--image alpine:3.22 -- sleep 60",
    )
    parser.add_argument("--image", required=True, help="镜像地址")
    parser.add_argument("--count", type=int, default=50, help="启动容器数量（默认 50）")
    parser.add_argument("--concurrency", type=int, default=1,
                        help="并发启动数（默认 1，即串行，得到最干净的单容器耗时）")
    parser.add_argument("--warmup", type=int, default=1,
                        help="预热容器数，不计入统计（默认 1，用于抵消首次拉起镜像层的开销）")
    parser.add_argument("--ready", choices=["none", "tcp", "http", "log"], default="none",
                        help="就绪探测方式（默认 none）")
    parser.add_argument("--ready-port", type=int, default=8080, help="tcp/http 探测端口（默认 8080）")
    parser.add_argument("--ready-path", default="/actuator/health/readiness", help="http 探测路径")
    parser.add_argument("--ready-log-pattern", default="Started .* in .* seconds",
                        help="log 探测的正则（默认匹配 Spring Boot 启动日志）")
    parser.add_argument("--ready-timeout", type=float, default=120.0, help="单个容器就绪超时秒数（默认 120）")
    parser.add_argument("--ip-timeout", type=float, default=20.0,
                        help="等待容器分配 IP 的超时秒数（默认 20，网络模式不对时快速失败）")
    parser.add_argument("--max-consecutive-failures", type=int, default=3,
                        help="连续失败达到该数量就中止整轮测试（默认 3，设 0 表示不中止）")
    parser.add_argument("--poll-interval", type=float, default=0.02, help="探测轮询间隔秒（默认 0.02）")
    parser.add_argument("--memory", default=None, help="每容器内存上限，如 512m（JVM 镜像强烈建议设置）")
    parser.add_argument("--cpus", default=None, help="每容器 CPU 上限，如 1")
    parser.add_argument("--platform", default=None, help="指定平台，如 linux/arm64")
    parser.add_argument("--env", action="append", default=[], help="传给容器的环境变量 K=V（可重复）")
    parser.add_argument("--docker-arg", action="append", default=[],
                        help="附加到 docker run 的原始参数（可重复），如 --docker-arg '--network mynet'")
    parser.add_argument("--cleanup", choices=["each", "end"], default="each",
                        help="each=测完一个删一个（默认）；end=全部保留到结束再删，用于测并发密度")
    parser.add_argument("--name-prefix", default="cstart-bench", help="容器名前缀（默认 cstart-bench）")
    parser.add_argument("--pull", action="store_true", help="开始前先 docker pull")
    parser.add_argument("--json", dest="json_out", default=None, help="把完整结果写入 JSON 文件")
    parser.add_argument("--csv", dest="csv_out", default=None, help="把逐容器原始数据写入 CSV 文件")
    parser.add_argument("--quiet", action="store_true", help="不打印逐容器进度")
    parser.add_argument("cmd", nargs=argparse.REMAINDER, help="容器启动命令（放在 -- 之后）")

    args = parser.parse_args(argv)
    if args.cmd and args.cmd[0] == "--":
        args.cmd = args.cmd[1:]
    if args.count < 1:
        parser.error("--count 至少为 1")
    if args.concurrency < 1:
        parser.error("--concurrency 至少为 1")
    if args.warmup < 0:
        parser.error("--warmup 不能为负数")
    return args


def main(argv: list[str]) -> int:
    args = parse_args(argv)

    if sh(["docker", "version", "--format", "{{.Server.Version}}"], timeout=30).returncode != 0:
        print("错误：连不上 docker daemon（是否需要 sudo 或把当前用户加入 docker 组？）", file=sys.stderr)
        return 2

    if args.pull:
        print(f"拉取镜像 {args.image} ...", file=sys.stderr)
        try:
            sh_ok(["docker", "pull", args.image], timeout=1800)
        except RuntimeError as exc:
            print(f"错误：{exc}", file=sys.stderr)
            return 2

    try:
        image = image_info(args.image)
    except (RuntimeError, IndexError, json.JSONDecodeError):
        print(f"错误：本地找不到镜像 {args.image}，先 docker pull 或加 --pull", file=sys.stderr)
        return 2

    host = host_info()
    cleanup(args.name_prefix, quiet=True)  # 清掉上一次可能残留的容器

    interrupted = {"flag": False}

    def on_signal(signum, _frame):
        interrupted["flag"] = True
        print("\n收到中断信号，正在清理容器 ...", file=sys.stderr)
        cleanup(args.name_prefix)
        sys.exit(130)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)

    total = args.warmup + args.count
    samples: list[Sample] = []
    done = 0
    consecutive_failures = 0
    aborted = {"flag": False, "reason": ""}
    lock = threading.Lock()

    def task(idx: int) -> Sample:
        nonlocal done, consecutive_failures
        if aborted["flag"]:
            return Sample(index=idx, name=f"{args.name_prefix}-{idx:04d}",
                          warmup=idx < args.warmup, ok=False, skipped=True, error="已中止")

        s = measure_one(args, idx, warmup=idx < args.warmup)
        with lock:
            done += 1
            if s.ok:
                consecutive_failures = 0
            else:
                consecutive_failures += 1
                if 0 < args.max_consecutive_failures <= consecutive_failures and not aborted["flag"]:
                    aborted["flag"] = True
                    aborted["reason"] = f"连续 {consecutive_failures} 个容器失败，已中止（最后原因：{s.error}）"
                    print(f"\n!! {aborted['reason']}", file=sys.stderr)
                    print("   排查建议：docker logs 看容器日志；确认 --ready 模式、端口、内存上限是否合适；"
                          "加 --max-consecutive-failures 0 可强制跑完全部样本。", file=sys.stderr)
            if not args.quiet:
                tag = "预热" if s.warmup else f"{done - args.warmup if done > args.warmup else done}/{args.count}"
                if not s.ok:
                    detail = f"失败：{s.error}"
                elif s.ready_ms is not None:
                    detail = f"就绪 {s.ready_ms:8.1f} ms  (docker run {s.cli_start_ms:6.1f} ms)"
                else:
                    detail = f"docker run {s.cli_start_ms:6.1f} ms"
                print(f"  [{tag:>7}] {s.name}  {detail}", file=sys.stderr)
        return s

    print(f"开始：{total} 个容器（{args.warmup} 预热 + {args.count} 计入统计），并发 {args.concurrency}",
          file=sys.stderr)
    started_at = datetime.now(timezone.utc)
    t_begin = time.perf_counter()

    if args.concurrency == 1:
        for idx in range(total):
            samples.append(task(idx))
    else:
        # 预热单独串行跑，避免污染并发测量
        for idx in range(args.warmup):
            samples.append(task(idx))
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            samples.extend(pool.map(task, range(args.warmup, total)))

    wall = time.perf_counter() - t_begin
    samples.sort(key=lambda s: s.index)

    if args.cleanup == "end":
        cleanup(args.name_prefix)

    report = render_report(args, host, image, samples, started_at, wall, note=aborted["reason"])
    print(report)

    if args.json_out:
        write_json(args.json_out, args, host, image, samples, started_at, wall)
        print(f"JSON 已写入 {args.json_out}", file=sys.stderr)
    if args.csv_out:
        write_csv(args.csv_out, samples)
        print(f"CSV 已写入 {args.csv_out}", file=sys.stderr)

    failures = sum(1 for s in samples if not s.ok and not s.warmup)
    return 1 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        sys.exit(130)
