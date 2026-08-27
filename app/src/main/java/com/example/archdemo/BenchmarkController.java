package com.example.archdemo;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.LinkedHashMap;
import java.util.Map;

import org.springframework.http.MediaType;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RequestParam;
import org.springframework.web.bind.annotation.RestController;
import org.springframework.web.server.ResponseStatusException;
import org.springframework.http.HttpStatus;

/**
 * 一个非常轻量的 CPU 压测接口，用于在同一份镜像下对比
 * x86 (c6a) 与 Graviton (c6g) 节点的相对性能。
 *
 * <p>注意：这只是 demo 级别的粗略对比，不能替代正式的基准测试。
 */
@RestController
public class BenchmarkController {

    private static final int MAX_ITERATIONS = 20_000_000;

    private final ArchInfoService archInfoService;

    public BenchmarkController(ArchInfoService archInfoService) {
        this.archInfoService = archInfoService;
    }

    @GetMapping(value = "/api/bench", produces = MediaType.APPLICATION_JSON_VALUE)
    public Map<String, Object> bench(
            @RequestParam(defaultValue = "2000000") int iterations,
            @RequestParam(defaultValue = "1") int warmupRounds) {

        if (iterations < 1 || iterations > MAX_ITERATIONS) {
            throw new ResponseStatusException(HttpStatus.BAD_REQUEST,
                    "iterations 必须在 1 和 " + MAX_ITERATIONS + " 之间");
        }

        // 预热，让 JIT 完成编译，避免解释执行影响对比结果
        for (int i = 0; i < Math.max(0, warmupRounds); i++) {
            runSha256(Math.min(iterations, 50_000));
        }

        long start = System.nanoTime();
        long checksum = runSha256(iterations);
        long elapsedNanos = System.nanoTime() - start;

        double elapsedMillis = elapsedNanos / 1_000_000.0;
        double opsPerSecond = elapsedNanos == 0 ? 0 : iterations / (elapsedNanos / 1_000_000_000.0);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("workload", "sha-256 hash loop");
        result.put("iterations", iterations);
        result.put("warmupRounds", warmupRounds);
        result.put("elapsedMillis", Math.round(elapsedMillis * 100) / 100.0);
        result.put("opsPerSecond", Math.round(opsPerSecond));
        result.put("checksum", checksum);
        result.put("osArch", archInfoService.osArch());
        result.put("platform", archInfoService.platformLabel());
        result.put("availableProcessors", Runtime.getRuntime().availableProcessors());
        result.put("podName", System.getenv().getOrDefault("POD_NAME", "n/a"));
        result.put("nodeName", System.getenv().getOrDefault("NODE_NAME", "n/a"));
        return result;
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
}
