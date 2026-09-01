package com.example.archdemo;

/**
 * 自研 C 库 libarchdemo_native.so 的 JNI 绑定。
 *
 * <p>这个 .so 由镜像构建过程中的 native-builder 阶段编译产出（见 app/Dockerfile），
 * 源码在 app/native/ 下，是纯标量 C，不含 SIMD。
 *
 * <p>关键点：jar 与架构无关，但这个 .so **必须为每种架构分别编译**。
 * 引入 JNI 之后，Java 镜像也变成了"要按架构构建"的产物，
 * 和 Go / C++ 一样——这正是本 demo 想让客户看到的迁移成本差异。
 *
 * <p>加载失败时不抛异常，只把 {@link #isAvailable()} 置为 false，
 * 这样本机不带 .so 直接 {@code java -jar} 也能启动，接口会如实报告"不可用"。
 */
public final class NativeLib {

    /** 镜像里 .so 的安装路径，与 Dockerfile 中的 java.library.path 一致 */
    private static final String LIBRARY_NAME = "archdemo_native";
    private static final String FALLBACK_PATH = "/app/lib/libarchdemo_native.so";

    private static final boolean AVAILABLE;
    private static final String LOAD_ERROR;

    static {
        boolean loaded = false;
        String error = null;
        try {
            // 优先走 java.library.path（Dockerfile 里设为 /app/lib）
            System.loadLibrary(LIBRARY_NAME);
            loaded = true;
        } catch (UnsatisfiedLinkError primary) {
            try {
                System.load(FALLBACK_PATH);
                loaded = true;
            } catch (UnsatisfiedLinkError fallback) {
                error = primary.getMessage() + " / " + fallback.getMessage();
            }
        }
        AVAILABLE = loaded;
        LOAD_ERROR = error;
    }

    private NativeLib() {
    }

    public static boolean isAvailable() {
        return AVAILABLE;
    }

    public static String loadError() {
        return LOAD_ERROR;
    }

    /** 库与编译期信息，例如 "archdemo_native 1.0 (gcc 11.5.0, arm64, scalar/no-simd)" */
    public static native String nativeInfo();

    /** .so 的编译目标架构："amd64" / "arm64" */
    public static native String nativeArch();

    /** 在 C 侧对 data 连续做 iterations 轮 CRC-32，返回累计值 */
    public static native long crc32Loop(byte[] data, int iterations);

    /** 在 C 侧对 data 连续做 iterations 轮 FNV-1a 64 位哈希，返回累计值 */
    public static native long fnv1a64Loop(byte[] data, int iterations);

    /** 安全包装：.so 不可用时返回占位串，避免调用方到处 try/catch */
    public static String infoOrUnavailable() {
        if (!AVAILABLE) {
            return "unavailable";
        }
        try {
            return nativeInfo();
        } catch (UnsatisfiedLinkError e) {
            return "unavailable";
        }
    }

    public static String archOrUnknown() {
        if (!AVAILABLE) {
            return "unknown";
        }
        try {
            return nativeArch();
        } catch (UnsatisfiedLinkError e) {
            return "unknown";
        }
    }
}
