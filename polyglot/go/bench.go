package main

import (
	"crypto/sha256"
	"fmt"
	"runtime"
	"sync"
	"time"
)

// Go 侧压测：与 Python / C++ / Java 版本跑完全相同的负载
//   每次迭代：sha256(payload || byte(i & 0xFF))，并累加哈希首尾字节防止被优化掉
//
// 每个 worker 各跑 iterations 次，总次数 = iterations × threads，
// 聚合吞吐 = 总次数 / 墙钟耗时，用于多核对比。
func benchGo(iterations, threads int) benchResult {
	// 预热，让 Go 的内联/分支预测和 CPU cache 进入稳定状态
	warmup := iterations
	if warmup > warmupIterationsCap {
		warmup = warmupIterationsCap
	}
	runParallelGo(threads, warmup)

	start := time.Now()
	checksums := runParallelGo(threads, iterations)
	elapsed := time.Since(start)

	var checksum int64
	for _, c := range checksums {
		checksum += c
	}

	total := int64(iterations) * int64(threads)
	elapsedMillis := float64(elapsed.Microseconds()) / 1000.0
	seconds := elapsed.Seconds()

	var aggregate, perThread int64
	if seconds > 0 {
		aggregate = int64(float64(total) / seconds)
		perThread = aggregate / int64(threads)
	}

	mode := "multi-thread"
	if threads == 1 {
		mode = "single-thread"
	}

	return benchResult{
		Lang:                  "go",
		Runtime:               runtime.Version(),
		Mode:                  mode,
		Threads:               threads,
		IterationsPerThread:   iterations,
		TotalIterations:       total,
		ElapsedMillis:         roundTo(elapsedMillis, 2),
		OpsPerSecond:          aggregate,
		OpsPerSecondPerThread: perThread,
		Checksum:              checksum,
		Note:                  fmt.Sprintf("goroutines, GOMAXPROCS=%d", runtime.GOMAXPROCS(0)),
	}
}

func runParallelGo(threads, iterations int) []int64 {
	checksums := make([]int64, threads)
	var wg sync.WaitGroup
	wg.Add(threads)
	for i := 0; i < threads; i++ {
		go func(idx int) {
			defer wg.Done()
			checksums[idx] = sha256Loop(iterations)
		}(i)
	}
	wg.Wait()
	return checksums
}

func sha256Loop(iterations int) int64 {
	buf := make([]byte, len(payload)+1)
	copy(buf, payload)
	digest := sha256.New()
	sum := make([]byte, 0, sha256.Size)

	var checksum int64
	for i := 0; i < iterations; i++ {
		buf[len(buf)-1] = byte(i & 0xFF)
		digest.Reset()
		digest.Write(buf)
		sum = digest.Sum(sum[:0])
		checksum += int64(sum[0]) + int64(sum[len(sum)-1])
	}
	return checksum
}
