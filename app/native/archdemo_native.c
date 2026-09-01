/*
 * archdemo_native 的实现：纯标量 C，刻意不使用任何 SIMD intrinsics，
 * 也不使用 -march=native 之类的架构特定编译选项。
 *
 * 这样同一份 C 源码在 x86_64 与 aarch64 上都能直接编译通过，
 * 唯一的要求就是"必须各编译一次"——这正是要演示的点。
 */
#include "archdemo_native.h"

#define STRINGIFY_INNER(x) #x
#define STRINGIFY(x) STRINGIFY_INNER(x)

#if defined(__aarch64__)
#define ARCHDEMO_ARCH "arm64"
#elif defined(__x86_64__)
#define ARCHDEMO_ARCH "amd64"
#else
#define ARCHDEMO_ARCH "unknown"
#endif

#if defined(__clang__)
#define ARCHDEMO_CC "clang " __clang_version__
#elif defined(__GNUC__)
#define ARCHDEMO_CC "gcc " STRINGIFY(__GNUC__) "." STRINGIFY(__GNUC_MINOR__) "." STRINGIFY(__GNUC_PATCHLEVEL__)
#else
#define ARCHDEMO_CC "unknown-cc"
#endif

const char *archdemo_native_info(void) {
    return "archdemo_native 1.0 (" ARCHDEMO_CC ", " ARCHDEMO_ARCH ", scalar/no-simd)";
}

const char *archdemo_native_arch(void) {
    return ARCHDEMO_ARCH;
}

/* CRC-32 查表，首次调用时惰性初始化 */
static uint32_t crc_table[256];
static int crc_table_ready = 0;

static void init_crc_table(void) {
    for (uint32_t i = 0; i < 256; ++i) {
        uint32_t c = i;
        for (int k = 0; k < 8; ++k) {
            c = (c & 1u) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        }
        crc_table[i] = c;
    }
    crc_table_ready = 1;
}

static uint32_t crc32_once(const uint8_t *data, size_t len) {
    uint32_t crc = 0xFFFFFFFFu;
    for (size_t i = 0; i < len; ++i) {
        crc = crc_table[(crc ^ data[i]) & 0xFFu] ^ (crc >> 8);
    }
    return crc ^ 0xFFFFFFFFu;
}

uint64_t archdemo_crc32_loop(const uint8_t *data, size_t len, uint32_t iterations) {
    if (data == NULL || len == 0) {
        return 0;
    }
    if (!crc_table_ready) {
        init_crc_table();
    }
    uint64_t acc = 0;
    for (uint32_t i = 0; i < iterations; ++i) {
        /* 每轮改一个字节，避免编译器把循环整体提出去 */
        uint32_t crc = crc32_once(data, len);
        acc += (uint64_t)crc + (uint64_t)(i & 0xFFu);
    }
    return acc;
}

uint64_t archdemo_fnv1a64_loop(const uint8_t *data, size_t len, uint32_t iterations) {
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
