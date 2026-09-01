// 多语言（Go / Python / C++）多架构 demo 服务。
//
// 一个镜像里装了三种语言的实现：
//   - Go   ：本进程，HTTP 前门 + 压测
//   - Python：exec /app/bench.py（解释执行，源码与架构无关）
//   - C++  ：exec /app/bench-cpp（原生二进制，必须按架构分别编译）
//
// 三者跑同一个负载（SHA-256 循环），因此可以在同一台机器上横向比语言，
// 也可以把同一个镜像 tag 分别跑在 x86 与 Graviton 上纵向比架构。
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"net/http"
	"os"
	"os/exec"
	"runtime"
	"strconv"
	"strings"
	"sync"
	"time"
)

const (
	payload             = "eks-multi-arch-demo-payload"
	defaultIterations   = 2_000_000
	maxIterations       = 20_000_000
	maxThreads          = 64
	warmupIterationsCap = 50_000
	benchTimeout        = 5 * time.Minute

	pythonBench = "/app/bench.py"
	cppBench    = "/app/bench-cpp"
)

// 各语言压测结果的统一结构，Python / C++ 子进程输出同样的字段
type benchResult struct {
	Lang                  string  `json:"lang"`
	Runtime               string  `json:"runtime"`
	Mode                  string  `json:"mode"`
	Threads               int     `json:"threads"`
	IterationsPerThread   int     `json:"iterationsPerThread"`
	TotalIterations       int64   `json:"totalIterations"`
	ElapsedMillis         float64 `json:"elapsedMillis"`
	OpsPerSecond          int64   `json:"opsPerSecond"`
	OpsPerSecondPerThread int64   `json:"opsPerSecondPerThread"`
	Checksum              int64   `json:"checksum"`
	// 子进程启动开销（wall - 子进程自报的计算耗时），只对 Python / C++ 有意义
	SpawnMillis float64 `json:"spawnMillis,omitempty"`
	Note        string  `json:"note,omitempty"`
	Error       string  `json:"error,omitempty"`
}

var (
	runtimeVersions = map[string]string{}
	versionOnce     sync.Once
	// 容器实际可用的 CPU 数（读 cgroup 配额算出来，不是宿主机核数）
	effectiveCPUs int
)

func main() {
	effectiveCPUs = detectCPUs()
	// Go 默认把 GOMAXPROCS 设成宿主机核数，在容器里会超配。
	// 这是 Go 服务上 Kubernetes 的经典坑，这里按 cgroup 配额纠正。
	runtime.GOMAXPROCS(effectiveCPUs)

	collectVersions()

	mux := http.NewServeMux()
	mux.HandleFunc("/", handleHome)
	mux.HandleFunc("/api/info", handleInfo)
	mux.HandleFunc("/api/bench", handleBench)
	mux.HandleFunc("/api/native", handleNative)
	mux.HandleFunc("/api/simd", handleSimd)
	mux.HandleFunc("/healthz", handleHealth)
	mux.HandleFunc("/readyz", handleHealth)

	addr := ":" + envOr("PORT", "8080")
	log.Printf("polyglot-arch-demo 启动：addr=%s arch=%s numcpu=%d gomaxprocs=%d",
		addr, runtime.GOARCH, runtime.NumCPU(), runtime.GOMAXPROCS(0))

	server := &http.Server{
		Addr:              addr,
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
	}
	if err := server.ListenAndServe(); err != nil && err != http.ErrServerClosed {
		log.Fatalf("服务退出：%v", err)
	}
}

// ---------------------------------------------------------------- handlers

func handleHealth(w http.ResponseWriter, _ *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	_, _ = w.Write([]byte(`{"status":"UP"}`))
}

func handleHome(w http.ResponseWriter, r *http.Request) {
	if r.URL.Path != "/" {
		http.NotFound(w, r)
		return
	}
	w.Header().Set("Content-Type", "text/plain; charset=utf-8")
	fmt.Fprintf(w, `EKS multi-arch polyglot demo (Go / Python / C++)
------------------------------------------------------------
CPU 架构 (GOARCH)   : %s
平台                : %s
宿主机可见核数      : %d
容器可用核数(cgroup): %d   <- GOMAXPROCS 已按这个值设置
Go                  : %s
Python              : %s
C++                 : %s
------------------------------------------------------------
原生依赖 / SIMD
  CGO 自研 C 库     : %s
  C++ SIMD 路径     : %s
------------------------------------------------------------
Pod                 : %s
Node                : %s
节点组              : %s
实例类型            : %s
------------------------------------------------------------
JSON 信息 : /api/info
三语言压测: /api/bench?lang=all&iterations=2000000
单语言压测: /api/bench?lang=go|python|cpp&threads=1
CGO 原生库: /api/native
C++ SIMD  : /api/simd?bytes=1048576&iterations=200
`,
		runtime.GOARCH, platformLabel(), runtime.NumCPU(), effectiveCPUs,
		runtimeVersions["go"], runtimeVersions["python"], runtimeVersions["cpp"],
		runtimeVersions["cgoNative"], runtimeVersions["cppSimd"],
		envOr("POD_NAME", "n/a"), envOr("NODE_NAME", "n/a"),
		envOr("NODE_GROUP", "n/a"), envOr("NODE_INSTANCE_TYPE", "n/a"))
}

func handleInfo(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, map[string]any{
		"app": map[string]any{
			"name":      "polyglot-arch-demo",
			"version":   envOr("APP_VERSION", "dev"),
			"languages": []string{"go", "python", "cpp"},
			"timestamp": time.Now().UTC().Format(time.RFC3339),
		},
		"architecture": map[string]any{
			"osArch":         runtime.GOARCH,
			"normalizedArch": runtime.GOARCH,
			"platform":       platformLabel(),
			"os":             runtime.GOOS,
			"buildPlatform":  envOr("TARGET_PLATFORM", "n/a"),
		},
		"runtimes": map[string]any{
			"go":     runtimeVersions["go"],
			"python": runtimeVersions["python"],
			"cpp":    runtimeVersions["cpp"],
		},
		"nativeDependencies": map[string]any{
			// 自研 C 库，经 CGO 链接；必须按架构分别编译
			"cgoLib":     runtimeVersions["cgoNative"],
			"cgoLibArch": nativeLibArch(),
			"cgoEnabled": true,
			// C++ 侧编译期选中的 SIMD 指令集
			"cppSimdPath": runtimeVersions["cppSimd"],
		},
		"resources": map[string]any{
			"hostCPUs":      runtime.NumCPU(),
			"containerCPUs": effectiveCPUs,
			"gomaxprocs":    runtime.GOMAXPROCS(0),
		},
		"kubernetes": map[string]any{
			"podName":          envOr("POD_NAME", "n/a"),
			"podIP":            envOr("POD_IP", "n/a"),
			"namespace":        envOr("POD_NAMESPACE", "n/a"),
			"nodeName":         envOr("NODE_NAME", "n/a"),
			"nodeGroup":        envOr("NODE_GROUP", "n/a"),
			"nodeInstanceType": envOr("NODE_INSTANCE_TYPE", "n/a"),
			"hostname":         hostname(),
		},
	})
}

func handleBench(w http.ResponseWriter, r *http.Request) {
	lang := strings.ToLower(r.URL.Query().Get("lang"))
	if lang == "" {
		lang = "all"
	}

	iterations, err := intParam(r, "iterations", defaultIterations)
	if err != nil || iterations < 1 || iterations > maxIterations {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": fmt.Sprintf("iterations 必须在 1 和 %d 之间", maxIterations),
		})
		return
	}
	threads, err := intParam(r, "threads", 0)
	if err != nil || threads < 0 || threads > maxThreads {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": fmt.Sprintf("threads 必须在 0（自动）和 %d 之间", maxThreads),
		})
		return
	}
	if threads == 0 {
		threads = effectiveCPUs
	}

	var langs []string
	switch lang {
	case "all":
		langs = []string{"go", "python", "cpp"}
	case "go", "python", "cpp":
		langs = []string{lang}
	default:
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "lang 只支持 go / python / cpp / all",
		})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), benchTimeout)
	defer cancel()

	results := make([]benchResult, 0, len(langs))
	for _, l := range langs {
		switch l {
		case "go":
			results = append(results, benchGo(iterations, threads))
		case "python":
			results = append(results, runExternal(ctx, "python", "python3",
				[]string{pythonBench, "--iterations", strconv.Itoa(iterations), "--threads", strconv.Itoa(threads)}))
		case "cpp":
			results = append(results, runExternal(ctx, "cpp", cppBench,
				[]string{"--iterations", strconv.Itoa(iterations), "--threads", strconv.Itoa(threads)}))
		}
	}

	writeJSON(w, http.StatusOK, map[string]any{
		"workload":            "sha-256 hash loop",
		"iterationsPerThread": iterations,
		"threads":             threads,
		"osArch":              runtime.GOARCH,
		"platform":            platformLabel(),
		"containerCPUs":       effectiveCPUs,
		"podName":             envOr("POD_NAME", "n/a"),
		"nodeName":            envOr("NODE_NAME", "n/a"),
		"nodeInstanceType":    envOr("NODE_INSTANCE_TYPE", "n/a"),
		"results":             results,
		"note":                "checksum 仅用于防止编译器/解释器把循环优化掉，跨语言不可比",
	})
}

// ---------------------------------------------------------------- 子进程

// 调用 Python / C++ 子程序跑压测。子程序自己计时并输出 JSON，
// 因此进程启动开销不会算进 elapsedMillis，而是单独放在 spawnMillis 里。
func runExternal(ctx context.Context, lang, bin string, args []string) benchResult {
	start := time.Now()
	cmd := exec.CommandContext(ctx, bin, args...)
	out, err := cmd.Output()
	wallMillis := float64(time.Since(start).Microseconds()) / 1000.0

	if err != nil {
		detail := err.Error()
		var exitErr *exec.ExitError
		if ok := asExitError(err, &exitErr); ok && len(exitErr.Stderr) > 0 {
			detail = strings.TrimSpace(string(exitErr.Stderr))
		}
		return benchResult{Lang: lang, Runtime: runtimeVersions[lang], Error: detail}
	}

	var res benchResult
	if err := json.Unmarshal(out, &res); err != nil {
		return benchResult{Lang: lang, Runtime: runtimeVersions[lang],
			Error: fmt.Sprintf("解析子进程输出失败：%v", err)}
	}
	res.Lang = lang
	if res.Runtime == "" {
		res.Runtime = runtimeVersions[lang]
	}
	res.SpawnMillis = roundTo(wallMillis-res.ElapsedMillis, 2)
	return res
}

func asExitError(err error, target **exec.ExitError) bool {
	if e, ok := err.(*exec.ExitError); ok {
		*target = e
		return true
	}
	return false
}

// ---------------------------------------------------------------- 版本信息

func collectVersions() {
	versionOnce.Do(func() {
		runtimeVersions["go"] = runtime.Version()
		runtimeVersions["python"] = firstLine(runCapture("python3", pythonBench, "--version"))
		runtimeVersions["cpp"] = firstLine(runCapture(cppBench, "--version"))
		// C++ 侧编译期选中的 SIMD 路径（x86 SSE2/AVX2 或 arm64 NEON）
		runtimeVersions["cppSimd"] = firstLine(runCapture(cppBench, "--simd-path"))
		// 自研 C 库（CGO 链接）的编译期信息
		runtimeVersions["cgoNative"] = nativeLibInfo()
	})
}

// handleNative：通过 CGO 调用自研 C 库 libgodemo_native.so
func handleNative(w http.ResponseWriter, r *http.Request) {
	iterations, err := intParam(r, "iterations", 20000)
	if err != nil || iterations < 1 || iterations > 5_000_000 {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "iterations 必须在 1 和 5000000 之间",
		})
		return
	}
	sizeBytes, err := intParam(r, "sizeBytes", 4096)
	if err != nil || sizeBytes < 64 || sizeBytes > 8<<20 {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "sizeBytes 必须在 64 和 8388608 之间",
		})
		return
	}

	payload := make([]byte, sizeBytes)
	for i := range payload {
		payload[i] = byte((i*31 + 7) & 0xFF)
	}

	libArch := nativeLibArch()
	writeJSON(w, http.StatusOK, map[string]any{
		"library":       "libgodemo_native.so（自研 C 库，纯标量，无 SIMD，经 CGO 调用）",
		"cgoEnabled":    true,
		"nativeInfo":    nativeLibInfo(),
		"nativeArch":    libArch,
		"goArch":        runtime.GOARCH,
		"archMatchesGo": libArch == runtime.GOARCH,
		"iterations":    iterations,
		"payloadBytes":  sizeBytes,
		"results":       runNativeBench(payload, iterations),
		"platform":      platformLabel(),
		"podName":       envOr("POD_NAME", "n/a"),
		"nodeName":      envOr("NODE_NAME", "n/a"),
		"note":          "nativeArch 来自 .so 的编译期宏，与 goArch 一致才说明链接到了正确架构的库",
	})
}

// handleSimd：调用 C++ 二进制的 SIMD 模式，对比 SIMD 与标量实现
func handleSimd(w http.ResponseWriter, r *http.Request) {
	bufferBytes, err := intParam(r, "bytes", 1<<20)
	if err != nil || bufferBytes < 64 || bufferBytes > 64<<20 {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "bytes 必须在 64 和 67108864 之间",
		})
		return
	}
	iterations, err := intParam(r, "iterations", 200)
	if err != nil || iterations < 1 || iterations > 100000 {
		writeJSON(w, http.StatusBadRequest, map[string]string{
			"error": "iterations 必须在 1 和 100000 之间",
		})
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), benchTimeout)
	defer cancel()

	out, execErr := exec.CommandContext(ctx, cppBench, "--simd",
		"--simd-bytes", strconv.Itoa(bufferBytes),
		"--simd-iterations", strconv.Itoa(iterations)).Output()

	var payload map[string]any
	if jsonErr := json.Unmarshal(out, &payload); jsonErr != nil {
		detail := jsonErr.Error()
		if execErr != nil {
			detail = execErr.Error()
		}
		writeJSON(w, http.StatusInternalServerError, map[string]string{
			"error": "调用 C++ SIMD 压测失败：" + detail,
		})
		return
	}

	// resultsMatch=false 时 C++ 侧会以退出码 1 返回，这里如实透传
	writeJSON(w, http.StatusOK, map[string]any{
		"osArch":           runtime.GOARCH,
		"platform":         platformLabel(),
		"compiledSimdPath": runtimeVersions["cppSimd"],
		"result":           payload,
		"podName":          envOr("POD_NAME", "n/a"),
		"nodeName":         envOr("NODE_NAME", "n/a"),
		"nodeInstanceType": envOr("NODE_INSTANCE_TYPE", "n/a"),
		"note":             "同一份 .cpp 用预编译宏分支：x86 走 SSE2/AVX2，arm64 走 NEON；resultsMatch 校验两条路径结果一致",
	})
}

func runCapture(bin string, args ...string) string {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, bin, args...).Output()
	if err != nil {
		return "unavailable"
	}
	return strings.TrimSpace(string(out))
}

// ---------------------------------------------------------------- 工具

func platformLabel() string {
	if runtime.GOARCH == "arm64" {
		return "AWS Graviton (aarch64)"
	}
	return "x86_64 (Intel/AMD)"
}

func envOr(key, fallback string) string {
	if v := strings.TrimSpace(os.Getenv(key)); v != "" {
		return v
	}
	return fallback
}

func hostname() string {
	if h, err := os.Hostname(); err == nil {
		return h
	}
	return envOr("HOSTNAME", "n/a")
}

func intParam(r *http.Request, name string, fallback int) (int, error) {
	raw := r.URL.Query().Get(name)
	if raw == "" {
		return fallback, nil
	}
	return strconv.Atoi(raw)
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	_ = enc.Encode(body)
}

func firstLine(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		return s[:i]
	}
	return s
}

func roundTo(v float64, digits int) float64 {
	pow := 1.0
	for i := 0; i < digits; i++ {
		pow *= 10
	}
	return float64(int64(v*pow+0.5)) / pow
}
