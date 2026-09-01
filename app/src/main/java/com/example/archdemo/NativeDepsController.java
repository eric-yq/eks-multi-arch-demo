package com.example.archdemo;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;

import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

/**
 * 原生依赖相关接口：
 * <ul>
 *   <li>{@code GET /api/compress} —— 第三方带原生代码的依赖（lz4-java，jar 内置各架构 .so）</li>
 *   <li>{@code GET /api/native}   —— 自研 C 库（libarchdemo_native.so，按架构编译）+ JNI 调用</li>
 * </ul>
 *
 * 两者代表 Graviton 迁移里原生依赖的两种情况：
 * 上游已经打包好 aarch64（lz4-java），以及需要自己负责按架构构建（自研 .so）。
 */
@RestController
public class NativeDepsController {

    private static final int MAX_ITERATIONS = 2_000_000;
    private static final int MAX_THREADS = 64;

    private final Lz4Service lz4Service;
    private final ArchInfoService archInfoService;

    public NativeDepsController(Lz4Service lz4Service, ArchInfoService archInfoService) {
        this.lz4Service = lz4Service;
        this.archInfoService = archInfoService;
    }

    /**
     * @param threads 并发线程数，0 或不传 = 容器可见 vCPU 数（多核口径）
     */
    @GetMapping(value = "/api/compress", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> compress(
            @RequestParam(defaultValue = "262144") int sizeBytes,
            @RequestParam(defaultValue = "50") int iterations,
            @RequestParam(defaultValue = "0") int threads) {

        if (iterations < 1 || iterations > 100_000) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST, "iterations 必须在 1 和 100000 之间");
        }
        int workers = resolveThreads(threads);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("osArch", archInfoService.osArch());
        result.put("platform", archInfoService.platformLabel());
        result.putAll(lz4Service.roundTrip(sizeBytes, iterations, workers));
        result.put("note", "implementation=LZ4Factory:JNI 表示用上了 jar 内置的原生 .so，"
                + "x86 与 Graviton 都应如此；吞吐为多线程聚合值（threads 字段），"
                + "压缩与解压分两个并行阶段各自计时");
        return result;
    }

    /**
     * @param threads 并发线程数，0 或不传 = 容器可见 vCPU 数（多核口径）
     */
    @GetMapping(value = "/api/native", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> nativeLib(
            @RequestParam(defaultValue = "20000") int iterations,
            @RequestParam(defaultValue = "4096") int sizeBytes,
            @RequestParam(defaultValue = "0") int threads) {

        if (iterations < 1 || iterations > MAX_ITERATIONS) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "iterations 必须在 1 和 " + MAX_ITERATIONS + " 之间");
        }
        int workers = resolveThreads(threads);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("osArch", archInfoService.osArch());
        result.put("platform", archInfoService.platformLabel());
        result.put("library", "libarchdemo_native.so（自研，纯标量 C，无 SIMD）");
        result.put("available", NativeLib.isAvailable());

        if (!NativeLib.isAvailable()) {
            result.put("loadError", NativeLib.loadError());
            result.put("hint", "本机直接 java -jar 时没有 .so 属正常；镜像里由 native-builder 阶段编译并放在 /app/lib");
            return result;
        }

        // 源数据只读，多线程共享；JNI 侧只读取数组，不写回
        byte[] payload = buildPayload(sizeBytes);
        long[] crcResults = new long[workers];
        long[] fnvResults = new long[workers];

        // 预热：让 JIT 与 JNI 首次调用的开销不计入吞吐
        NativeLib.crc32Loop(payload, Math.min(iterations, 200));
        NativeLib.fnv1a64Loop(payload, Math.min(iterations, 200));

        ExecutorService pool = Executors.newFixedThreadPool(workers, Lz4Service.workerFactory());
        long crcWallNanos;
        long fnvWallNanos;
        try {
            crcWallNanos = Lz4Service.runPhase(pool, workers,
                    idx -> crcResults[idx] = NativeLib.crc32Loop(payload, iterations));
            fnvWallNanos = Lz4Service.runPhase(pool, workers,
                    idx -> fnvResults[idx] = NativeLib.fnv1a64Loop(payload, iterations));
        } finally {
            pool.shutdownNow();
        }

        // 聚合吞吐：所有线程合计处理的数据量 ÷ 墙钟耗时
        double totalMiB = (double) payload.length * iterations * workers / (1024 * 1024);

        result.put("nativeInfo", NativeLib.nativeInfo());
        result.put("nativeArch", NativeLib.nativeArch());
        result.put("archMatchesJvm", NativeLib.nativeArch().equals(archInfoService.normalizedArch()));
        result.put("mode", workers == 1 ? "single-thread" : "multi-thread");
        result.put("threads", workers);
        result.put("availableProcessors", Runtime.getRuntime().availableProcessors());
        result.put("iterationsPerThread", iterations);
        result.put("iterations", iterations);
        result.put("payloadBytes", payload.length);
        result.put("totalMiBProcessed", round2(totalMiB));
        result.put("crc32", Map.of(
                "checksum", crcResults[0],
                "elapsedMillis", round2(crcWallNanos / 1_000_000.0),
                "miBPerSecond", throughput(totalMiB, crcWallNanos),
                "miBPerSecondPerThread", throughput(totalMiB / workers, crcWallNanos)));
        result.put("fnv1a64", Map.of(
                "checksum", fnvResults[0],
                "elapsedMillis", round2(fnvWallNanos / 1_000_000.0),
                "miBPerSecond", throughput(totalMiB, fnvWallNanos),
                "miBPerSecondPerThread", throughput(totalMiB / workers, fnvWallNanos)));
        result.put("note", "nativeArch 来自 .so 的编译期宏，和 JVM 的 os.arch 一致才说明加载到了正确架构的库；"
                + "吞吐为多线程聚合值，每线程各跑 iterationsPerThread 轮");
        return result;
    }

    /** threads<=0 时取容器可见的 vCPU 数（受 limits.cpu 约束） */
    private static int resolveThreads(int requested) {
        int workers = requested > 0 ? requested : Runtime.getRuntime().availableProcessors();
        if (workers > MAX_THREADS) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "threads 不能超过 " + MAX_THREADS);
        }
        return Math.max(1, workers);
    }

    private static byte[] buildPayload(int sizeBytes) {
        int size = Math.max(64, Math.min(sizeBytes, 8 * 1024 * 1024));
        byte[] template = "eks-multi-arch-demo jni payload ".getBytes(StandardCharsets.UTF_8);
        byte[] payload = new byte[size];
        for (int i = 0; i < size; i++) {
            payload[i] = template[i % template.length];
        }
        return payload;
    }

    private static Object throughput(double totalMiB, long nanos) {
        if (nanos <= 0) {
            return 0;
        }
        return Math.round(totalMiB / (nanos / 1_000_000_000.0));
    }

    private static double round2(double value) {
        return Math.round(value * 100) / 100.0;
    }
}
