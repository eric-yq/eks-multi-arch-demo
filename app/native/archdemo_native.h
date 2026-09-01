/*
 * archdemo_native —— Java demo 的 C 依赖库（纯标量实现，不含任何 SIMD 代码）。
 *
 * 存在的意义：演示"带原生代码的依赖"在 Graviton 迁移中的处理方式。
 * jar 是架构无关的，但这个 .so 必须为每种架构分别编译，
 * 因此 Java 镜像从"一份产物通吃"变成了"和 Go/C++ 一样要按架构构建"。
 */
#ifndef ARCHDEMO_NATIVE_H
#define ARCHDEMO_NATIVE_H

#include <stddef.h>
#include <stdint.h>

/* 库与编译期信息，例如 "archdemo_native 1.0 (gcc 11.5.0, aarch64, scalar/no-simd)" */
const char *archdemo_native_info(void);

/* 编译目标架构，"amd64" / "arm64" / "unknown" */
const char *archdemo_native_arch(void);

/* CRC-32（IEEE 802.3，查表法，标量）。对 data 连续计算 iterations 轮，返回累计值。 */
uint64_t archdemo_crc32_loop(const uint8_t *data, size_t len, uint32_t iterations);

/* FNV-1a 64 位哈希（标量）。对 data 连续计算 iterations 轮，返回累计值。 */
uint64_t archdemo_fnv1a64_loop(const uint8_t *data, size_t len, uint32_t iterations);

#endif /* ARCHDEMO_NATIVE_H */
