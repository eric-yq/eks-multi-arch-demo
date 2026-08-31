package main

import (
	"math"
	"os"
	"runtime"
	"strconv"
	"strings"
)

// detectCPUs 返回容器实际可用的 CPU 数。
//
// runtime.NumCPU() 读的是宿主机核数，在 Kubernetes 里会无视 limits.cpu。
// 比如 4 核节点上给 limits.cpu=1 的容器，NumCPU() 仍然返回 4，
// Go 就会开 4 个 P 去抢 1 核的配额，导致大量上下文切换。
// 这里按 cgroup 配额算出真实可用核数（向上取整，至少 1）。
func detectCPUs() int {
	if n, ok := cgroupV2CPUs(); ok {
		return n
	}
	if n, ok := cgroupV1CPUs(); ok {
		return n
	}
	return runtime.NumCPU()
}

// cgroup v2: /sys/fs/cgroup/cpu.max 内容形如 "400000 100000"（quota period），
// 无限制时 quota 为 "max"
func cgroupV2CPUs() (int, bool) {
	data, err := os.ReadFile("/sys/fs/cgroup/cpu.max")
	if err != nil {
		return 0, false
	}
	fields := strings.Fields(string(data))
	if len(fields) != 2 || fields[0] == "max" {
		return 0, false
	}
	quota, err1 := strconv.ParseFloat(fields[0], 64)
	period, err2 := strconv.ParseFloat(fields[1], 64)
	if err1 != nil || err2 != nil || period <= 0 || quota <= 0 {
		return 0, false
	}
	return clampCPUs(quota / period), true
}

// cgroup v1: cpu.cfs_quota_us / cpu.cfs_period_us，quota 为 -1 表示无限制
func cgroupV1CPUs() (int, bool) {
	quota, ok1 := readInt("/sys/fs/cgroup/cpu/cpu.cfs_quota_us")
	period, ok2 := readInt("/sys/fs/cgroup/cpu/cpu.cfs_period_us")
	if !ok1 || !ok2 || quota <= 0 || period <= 0 {
		return 0, false
	}
	return clampCPUs(float64(quota) / float64(period)), true
}

func readInt(path string) (int64, bool) {
	data, err := os.ReadFile(path)
	if err != nil {
		return 0, false
	}
	v, err := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil {
		return 0, false
	}
	return v, true
}

func clampCPUs(v float64) int {
	n := int(math.Ceil(v))
	if n < 1 {
		return 1
	}
	if host := runtime.NumCPU(); n > host {
		return host
	}
	return n
}
