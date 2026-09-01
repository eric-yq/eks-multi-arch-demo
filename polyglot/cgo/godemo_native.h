/*
 * godemo_native —— Go demo 的 C 依赖库（纯标量实现，不含任何 SIMD 代码）。
 *
 * 由镜像构建过程中的 cgo-builder 阶段编译成 libgodemo_native.so，
 * Go 侧通过 CGO 链接调用（构建时 CGO_ENABLED=1）。
 *
 * 这个库的存在把 Go 从"纯静态、交叉编译一条命令搞定"变成了
 * "要为每种架构编译原生依赖"——和 C++ 一样的迁移成本。
 */
#ifndef GODEMO_NATIVE_H
#define GODEMO_NATIVE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 库与编译期信息，例如 "godemo_native 1.0 (gcc 12.2.0, arm64, scalar/no-simd)" */
const char *godemo_native_info(void);

/* 编译目标架构，"amd64" / "arm64" / "unknown" */
const char *godemo_native_arch(void);

/* Adler-32 校验和（标量）。对 data 连续计算 iterations 轮，返回累计值。 */
uint64_t godemo_adler32_loop(const uint8_t *data, size_t len, uint32_t iterations);

/* FNV-1a 64 位哈希（标量）。对 data 连续计算 iterations 轮，返回累计值。 */
uint64_t godemo_fnv1a64_loop(const uint8_t *data, size_t len, uint32_t iterations);

#ifdef __cplusplus
}
#endif

#endif /* GODEMO_NATIVE_H */
