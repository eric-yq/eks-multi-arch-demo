/*
 * godemo_native 的实现：纯标量 C，刻意不使用任何 SIMD intrinsics，
 * 也不使用 -march=native 之类架构特定编译选项。
 *
 * 同一份源码在 x86_64 与 aarch64 上都能直接编译，唯一要求是"各编译一次"。
 */
#include "godemo_native.h"

#define STRINGIFY_INNER(x) #x
#define STRINGIFY(x) STRINGIFY_INNER(x)

#if defined(__aarch64__)
#define GODEMO_ARCH "arm64"
#elif defined(__x86_64__)
#define GODEMO_ARCH "amd64"
#else
#define GODEMO_ARCH "unknown"
#endif

#if defined(__clang__)
#define GODEMO_CC "clang " __clang_version__
#elif defined(__GNUC__)
#define GODEMO_CC "gcc " STRINGIFY(__GNUC__) "." STRINGIFY(__GNUC_MINOR__) "." STRINGIFY(__GNUC_PATCHLEVEL__)
#else
#define GODEMO_CC "unknown-cc"
#endif

const char *godemo_native_info(void) {
    return "godemo_native 1.0 (" GODEMO_CC ", " GODEMO_ARCH ", scalar/no-simd)";
}

const char *godemo_native_arch(void) {
    return GODEMO_ARCH;
}

#define ADLER_MOD 65521u

static uint32_t adler32_once(const uint8_t *data, size_t len) {
    uint32_t a = 1;
    uint32_t b = 0;
    for (size_t i = 0; i < len; ++i) {
        a = (a + data[i]) % ADLER_MOD;
        b = (b + a) % ADLER_MOD;
    }
    return (b << 16) | a;
}

uint64_t godemo_adler32_loop(const uint8_t *data, size_t len, uint32_t iterations) {
    if (data == NULL || len == 0) {
        return 0;
    }
    uint64_t acc = 0;
    for (uint32_t i = 0; i < iterations; ++i) {
        acc += (uint64_t)adler32_once(data, len) + (uint64_t)(i & 0xFFu);
    }
    return acc;
}

uint64_t godemo_fnv1a64_loop(const uint8_t *data, size_t len, uint32_t iterations) {
    if (data == NULL || len == 0) {
        return 0;
    }
    uint64_t acc = 0;
    for (uint32_t i = 0; i < iterations; ++i) {
        uint64_t hash = 1469598103934665603ULL; /* FNV offset basis */
        for (size_t j = 0; j < len; ++j) {
            hash ^= (uint64_t)data[j];
            hash *= 1099511628211ULL; /* FNV prime */
        }
        hash ^= (uint64_t)(i & 0xFFu);
        acc += hash;
    }
    return acc;
}
