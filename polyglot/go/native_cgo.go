package main

// CGO 绑定：调用自研 C 库 libgodemo_native.so。
//
// 链接方式：
//   - CFLAGS  指向头文件所在目录
//   - LDFLAGS 指向 cgo-builder 阶段产出的 .so，并写入 rpath=/app/lib，
//     这样运行镜像里不需要设置 LD_LIBRARY_PATH 也能找到库
//   - ${SRCDIR} 由 cgo 展开为本文件所在目录，避免写死绝对路径
//
// 构建时必须 CGO_ENABLED=1；一旦启用 CGO，产出的二进制就不再是纯静态，
// 会动态链接 glibc，所以构建镜像与运行镜像的 glibc 必须兼容
// （本 demo 两者同为 Debian bookworm）。
//
// 注意：紧贴 import "C" 的那个 /* */ 注释是 **C 预处理源码**，
// 里面只能放 #cgo 指令和合法 C 代码，不能写说明文字，否则会被当成 C 语法报错。

/*
#cgo CFLAGS: -I${SRCDIR}/../cgo
#cgo LDFLAGS: -L${SRCDIR}/../cgo/out -lgodemo_native -Wl,-rpath,/app/lib
#include <stdlib.h>
#include "godemo_native.h"
*/
import "C"

import (
	"runtime"
	"time"
	"unsafe"
)

// nativeLibInfo 返回 .so 的编译期信息（编译器、目标架构）
func nativeLibInfo() string {
	return C.GoString(C.godemo_native_info())
}

// nativeLibArch 返回 .so 的编译目标架构，应与 runtime.GOARCH 一致
func nativeLibArch() string {
	return C.GoString(C.godemo_native_arch())
}

type nativeResult struct {
	Name          string  `json:"name"`
	Checksum      uint64  `json:"checksum"`
	ElapsedMillis float64 `json:"elapsedMillis"`
	MiBPerSecond  int64   `json:"miBPerSecond"`
}

// runNativeBench 通过 CGO 调用 C 库做两种标量哈希，返回耗时与吞吐。
//
// 注意 unsafe.Pointer(&payload[0]) 把 Go 内存直接交给 C：
// 调用期间必须保证这块内存不被 GC 移动，用 runtime.KeepAlive 兜底。
func runNativeBench(payload []byte, iterations int) []nativeResult {
	if len(payload) == 0 || iterations < 1 {
		return nil
	}

	ptr := (*C.uint8_t)(unsafe.Pointer(&payload[0]))
	length := C.size_t(len(payload))
	iters := C.uint32_t(iterations)
	totalMiB := float64(len(payload)) * float64(iterations) / (1024 * 1024)

	results := make([]nativeResult, 0, 2)

	start := time.Now()
	adler := uint64(C.godemo_adler32_loop(ptr, length, iters))
	adlerElapsed := time.Since(start)

	start = time.Now()
	fnv := uint64(C.godemo_fnv1a64_loop(ptr, length, iters))
	fnvElapsed := time.Since(start)

	runtime.KeepAlive(payload)

	results = append(results,
		nativeResult{
			Name:          "adler32 (C)",
			Checksum:      adler,
			ElapsedMillis: roundTo(float64(adlerElapsed.Microseconds())/1000.0, 2),
			MiBPerSecond:  throughputMiB(totalMiB, adlerElapsed),
		},
		nativeResult{
			Name:          "fnv1a64 (C)",
			Checksum:      fnv,
			ElapsedMillis: roundTo(float64(fnvElapsed.Microseconds())/1000.0, 2),
			MiBPerSecond:  throughputMiB(totalMiB, fnvElapsed),
		})
	return results
}

func throughputMiB(totalMiB float64, elapsed time.Duration) int64 {
	seconds := elapsed.Seconds()
	if seconds <= 0 {
		return 0
	}
	return int64(totalMiB / seconds)
}
