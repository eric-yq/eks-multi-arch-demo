package com.example.archdemo;

import java.nio.charset.StandardCharsets;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Random;

import net.jpountz.lz4.LZ4Compressor;
import net.jpountz.lz4.LZ4Factory;
import net.jpountz.lz4.LZ4FastDecompressor;
import net.jpountz.xxhash.XXHashFactory;

import org.springframework.stereotype.Service;

/**
 * lz4-java 的使用示例：压缩 / 解压往返 + 吞吐统计。
 *
 * <p>看点在 {@code implementation} 字段：{@link LZ4Factory#fastestInstance()} 会优先选
 * JNI 实现（jar 里自带各架构的 liblz4-java.so），拿不到才退回 Java 实现。
 * 在 x86 与 Graviton 上都应该显示 JNI —— 说明这个带原生代码的依赖两种架构都覆盖了。
 */
@Service
public class Lz4Service {

    private static final int MAX_PAYLOAD_BYTES = 64 * 1024 * 1024;

    private final LZ4Factory factory;
    private final XXHashFactory xxHashFactory;
    private final String fastestInstanceName;
    private final boolean nativeAvailable;
    private final String nativeLoadNote;

    public Lz4Service() {
        // fastestInstance() 在 Spring Boot fat jar 下**不会**选 JNI：
        // lz4-java 内部要求 Native 类由 system classloader 加载，
        // 而 fat jar 用的是 Spring 的 LaunchedClassLoader，条件不满足就直接退回纯 Java 实现。
        // 这是个真实存在的坑：不显式要求的话，jar 里自带的 aarch64 .so 根本不会被用到。
        this.fastestInstanceName = LZ4Factory.fastestInstance().toString();

        LZ4Factory resolved;
        XXHashFactory resolvedHash;
        boolean usingNative;
        String note;
        try {
            // 显式要求 JNI 实现：会把 jar 里对应架构的 liblz4-java.so 解压并加载
            resolved = LZ4Factory.nativeInstance();
            resolvedHash = XXHashFactory.nativeInstance();
            usingNative = true;
            note = "显式调用 nativeInstance() 加载 jar 内置的 .so；"
                    + "fastestInstance() 在 fat jar 下会返回 " + fastestInstanceName;
        } catch (Throwable t) {
            // 上游没有当前架构的 .so，或运行环境不允许加载时退回纯 Java
            resolved = LZ4Factory.fastestJavaInstance();
            resolvedHash = XXHashFactory.fastestJavaInstance();
            usingNative = false;
            note = "原生实现不可用，已退回纯 Java：" + t;
        }
        this.factory = resolved;
        this.xxHashFactory = resolvedHash;
        this.nativeAvailable = usingNative;
        this.nativeLoadNote = note;
    }

    /** 当前实际生效的 lz4 实现，如 "LZ4Factory:JNI" / "LZ4Factory:JavaUnsafe" */
    public String implementation() {
        return factory.toString();
    }

    public String xxHashImplementation() {
        return xxHashFactory.toString();
    }

    /** fastestInstance() 会选的实现，用于对比说明 fat jar 的影响 */
    public String fastestInstanceName() {
        return fastestInstanceName;
    }

    public String nativeLoadNote() {
        return nativeLoadNote;
    }

    /** 是否用上了 jar 内置的原生 .so */
    public boolean usingNativeImplementation() {
        return nativeAvailable && factory.toString().toLowerCase().contains("jni");
    }

    /**
     * 压缩 / 解压往返，并校验数据一致。
     *
     * @param sizeBytes  测试数据大小
     * @param iterations 往返轮数
     */
    public Map<String, Object> roundTrip(int sizeBytes, int iterations) {
        byte[] source = buildPayload(sizeBytes);

        LZ4Compressor compressor = factory.fastCompressor();
        LZ4FastDecompressor decompressor = factory.fastDecompressor();

        int maxCompressedLength = compressor.maxCompressedLength(source.length);
        byte[] compressed = new byte[maxCompressedLength];
        byte[] restored = new byte[source.length];

        // 预热，避免首轮 JIT / 原生库首次调用影响吞吐
        int warmupLength = compressor.compress(source, 0, source.length, compressed, 0, maxCompressedLength);
        decompressor.decompress(compressed, 0, restored, 0, source.length);

        long compressNanos = 0;
        long decompressNanos = 0;
        int compressedLength = warmupLength;

        for (int i = 0; i < iterations; i++) {
            long t0 = System.nanoTime();
            compressedLength = compressor.compress(source, 0, source.length, compressed, 0, maxCompressedLength);
            long t1 = System.nanoTime();
            decompressor.decompress(compressed, 0, restored, 0, source.length);
            long t2 = System.nanoTime();
            compressNanos += t1 - t0;
            decompressNanos += t2 - t1;
        }

        boolean roundTripOk = java.util.Arrays.equals(source, restored);
        long sourceHash = xxHashFactory.hash64().hash(source, 0, source.length, 0L);
        long restoredHash = xxHashFactory.hash64().hash(restored, 0, restored.length, 0L);

        double totalMiB = (double) source.length * iterations / (1024 * 1024);

        Map<String, Object> result = new LinkedHashMap<>();
        result.put("library", "lz4-java 1.8.0");
        result.put("implementation", implementation());
        result.put("usingNativeSo", usingNativeImplementation());
        result.put("fastestInstanceWouldPick", fastestInstanceName());
        result.put("nativeLoadNote", nativeLoadNote());
        result.put("xxHashImplementation", xxHashImplementation());
        result.put("iterations", iterations);
        result.put("originalBytes", source.length);
        result.put("compressedBytes", compressedLength);
        result.put("compressionRatio", round2((double) source.length / compressedLength));
        result.put("compressMillis", round2(compressNanos / 1_000_000.0));
        result.put("decompressMillis", round2(decompressNanos / 1_000_000.0));
        result.put("compressMiBPerSecond", throughput(totalMiB, compressNanos));
        result.put("decompressMiBPerSecond", throughput(totalMiB, decompressNanos));
        result.put("roundTripVerified", roundTripOk);
        result.put("xxHashMatch", sourceHash == restoredHash);
        return result;
    }

    /** 构造可压缩的测试数据：重复文本 + 少量随机噪声，压缩率更接近真实日志 */
    private byte[] buildPayload(int sizeBytes) {
        int size = Math.max(1024, Math.min(sizeBytes, MAX_PAYLOAD_BYTES));
        byte[] template = ("eks-multi-arch-demo lz4 payload | arch=" + System.getProperty("os.arch")
                + " | the quick brown fox jumps over the lazy dog | ").getBytes(StandardCharsets.UTF_8);

        byte[] payload = new byte[size];
        for (int i = 0; i < size; i++) {
            payload[i] = template[i % template.length];
        }
        // 每 512 字节插一个随机字节，避免压缩率高得不真实
        Random random = new Random(42);
        for (int i = 0; i < size; i += 512) {
            payload[i] = (byte) random.nextInt(256);
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
