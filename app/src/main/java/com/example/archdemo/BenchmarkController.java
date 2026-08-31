package com.example.archdemo;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.concurrent.Callable;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.atomic.AtomicInteger;

import org.springframework.http.HttpStatus;
import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;

/**
 * 轻量 CPU 压测接口，用于在同一份 jar / 同一个镜像下对比不同架构的表现。
 *
 * <p>支持两种口径，结论可能相反，演示时要分开讲：
 * <ul>
 *   <li>{@code threads=1}：单核标量性能。x86 单核主频高，往往更占优。</li>
 *   <li>{@code threads=<vCPU>}：把容器可见的全部核打满，看整机吞吐。
 *       Graviton 的 vCPU 是物理核（无 SMT），而 x86 的 4 vCPU 通常是 2 物理核 + 超线程，
 *       所以多线程下的聚合吞吐经常反超。</li>
 * </ul>
 *
 * <p>注意：容器必须给足 CPU 上限（{@code limits.cpu}），否则 cgroup 配额会把多线程压回单核。
 * 这只是 demo 级别的粗略对比，不能替代用真实业务负载做的基准测试。
 */
@RestController
public class BenchmarkController {

    /** 每个线程的迭代数上限 */
    private static final int MAX_ITERATIONS = 20_000_000;
    private static final int MAX_THREADS = 64;
    private static final int WARMUP_ITERATIONS = 50_000;

    private final ArchInfoService archInfoService;

    public BenchmarkController(ArchInfoService archInfoService) {
        this.archInfoService = archInfoService;
    }

    /**
     * @param iterations   每个线程执行的 SHA-256 次数（总次数 = iterations × threads）
     * @param threads      并发线程数，0 或不传表示使用容器可见的 vCPU 数
     * @param warmupRounds 计时前丢弃的预热轮数，用于让 JIT 完成编译
     */
    @GetMapping(value = "/api/bench", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> bench(
            @RequestParam(defaultValue = "2000000") int iterations,
            @RequestParam(defaultValue = "0") int threads,
            @RequestParam(defaultValue = "1") int warmupRounds) {

        int availableProcessors = Runtime.getRuntime().availableProcessors();
        int workers = threads > 0 ? threads : availableProcessors;

        if (iterations < 1 || iterations > MAX_ITERATIONS) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "iterations 必须在 1 和 " + MAX_ITERATIONS + " 之间");
        }
        if (workers < 1 || workers > MAX_THREADS) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "threads 必须在 1 和 " + MAX_THREADS + " 之间");
        }

        ExecutorService pool = Executors.newFixedThreadPool(workers, benchThreadFactory());
        try {
            // 预热：每个线程都要跑，避免第一次计时被 JIT 编译污染
            for (int round = 0; round < Math.max(0, warmupRounds); round++) {
                runParallel(pool, workers, Math.min(iterations, WARMUP_ITERATIONS));
            }

            long wallStart = System.nanoTime();
            List<WorkerResult> results = runParallel(pool, workers, iterations);
            long wallNanos = System.nanoTime() - wallStart;

            return buildReport(iterations, workers, availableProcessors, warmupRounds,
                    wallNanos, results);
        } finally {
            pool.shutdownNow();
        }
    }

    private Map<String, Object> buildReport(int iterations, int workers, int availableProcessors,
                                            int warmupRounds, long wallNanos,
                                            List<WorkerResult> results) {
        long totalIterations = (long) iterations * workers;
        double wallSeconds = wallNanos / 1_000_000_000.0;
        double wallMillis = wallNanos / 1_000_000.0;

        long checksum = 0;
        double minThreadMillis = Double.MAX_VALUE;
        double maxThreadMillis = 0;
        double perThreadOpsSum = 0;
        for (WorkerResult r : results) {
            checksum += r.checksum;
            double ms = r.elapsedNanos / 1_000_000.0;
            minThreadMillis = Math.min(minThreadMillis, ms);
            maxThreadMillis = Math.max(maxThreadMillis, ms);
            if (r.elapsedNanos > 0) {
                perThreadOpsSum += iterations / (r.elapsedNanos / 1_000_000_000.0);
            }
        }

        double aggregateOps = wallNanos == 0 ? 0 : totalIterations / wallSeconds;

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("workload", "sha-256 hash loop");
        result.put("mode", workers == 1 ? "single-thread" : "multi-thread");
        result.put("threads", workers);
        result.put("availableProcessors", availableProcessors);
        result.put("iterationsPerThread", iterations);
        result.put("totalIterations", totalIterations);
        result.put("warmupRounds", warmupRounds);
        result.put("elapsedMillis", round2(wallMillis));
        // 聚合吞吐：全部线程合计的每秒哈希次数，多核对比看这个
        result.put("opsPerSecond", Math.round(aggregateOps));
        // 单线程平均吞吐：反映单核性能
        result.put("opsPerSecondPerThread", Math.round(results.isEmpty() ? 0 : perThreadOpsSum / results.size()));
        result.put("threadMillisMin", round2(minThreadMillis == Double.MAX_VALUE ? 0 : minThreadMillis));
        result.put("threadMillisMax", round2(maxThreadMillis));
        result.put("checksum", checksum);
        result.put("osArch", archInfoService.osArch());
        result.put("platform", archInfoService.platformLabel());
        result.put("podName", System.getenv().getOrDefault("POD_NAME", "n/a"));
        result.put("nodeName", System.getenv().getOrDefault("NODE_NAME", "n/a"));
        result.put("nodeInstanceType", System.getenv().getOrDefault("NODE_INSTANCE_TYPE", "n/a"));
        return result;
    }

    /** 所有线程同时跑同样的负载，返回每个线程的耗时。 */
    private List<WorkerResult> runParallel(ExecutorService pool, int workers, int iterations) {
        List<Callable<WorkerResult>> tasks = new ArrayList<>(workers);
        for (int i = 0; i < workers; i++) {
            tasks.add(() -> {
                long start = System.nanoTime();
                long checksum = runSha256(iterations);
                return new WorkerResult(System.nanoTime() - start, checksum);
            });
        }
        try {
            List<WorkerResult> results = new ArrayList<>(workers);
            for (Future<WorkerResult> future : pool.invokeAll(tasks)) {
                results.add(future.get());
            }
            return results;
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new ResponseStatusException(HttpStatus.SERVICE_UNAVAILABLE, "压测被中断", e);
        } catch (ExecutionException e) {
            throw new ResponseStatusException(HttpStatus.INTERNAL_SERVER_ERROR, "压测执行失败", e);
        }
    }

    private long runSha256(int iterations) {
        MessageDigest digest;
        try {
            digest = MessageDigest.getInstance("SHA-256");
        } catch (NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 不可用", e);
        }

        byte[] payload = "eks-multi-arch-demo-payload".getBytes(StandardCharsets.UTF_8);
        long checksum = 0;
        for (int i = 0; i < iterations; i++) {
            digest.reset();
            digest.update(payload);
            digest.update((byte) (i & 0xFF));
            byte[] hash = digest.digest();
            checksum += hash[0] + hash[hash.length - 1];
        }
        return checksum;
    }

    private static ThreadFactory benchThreadFactory() {
        AtomicInteger seq = new AtomicInteger();
        return runnable -> {
            Thread thread = new Thread(runnable, "bench-worker-" + seq.incrementAndGet());
            thread.setDaemon(true);
            return thread;
        };
    }

    private static double round2(double value) {
        return Math.round(value * 100) / 100.0;
    }

    private static final class WorkerResult {
        final long elapsedNanos;
        final long checksum;

        WorkerResult(long elapsedNanos, long checksum) {
            this.elapsedNanos = elapsedNanos;
            this.checksum = checksum;
        }
    }
}
