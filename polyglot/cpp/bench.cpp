// C++ 侧压测：与 Go / Python / Java 版本跑完全相同的 SHA-256 负载。
//
// 由 Go 前门以子进程方式调用，自己计时并把 JSON 打到 stdout。
//
// 用 OpenSSL 的 EVP 接口而不是手写 SHA-256：OpenSSL 会用到 x86 的 SHA-NI 与
// ARMv8 的 crypto 扩展，这样才和 Go/Python/Java（同样走硬件加速）口径一致；
// 手写标量实现会让 C++ 看起来无端慢一截。
//
// 这个文件也是整个 demo 里"Graviton 迁移最难的部分"的具体体现：
// 它必须为每种架构分别编译，不像 jar 或 .py 那样一份产物通吃。
#include <openssl/crypto.h>
#include <openssl/evp.h>

#include <chrono>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <iostream>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

// ---------------------------------------------------------------------------
// SIMD 头文件按架构包含：同一份源码，靠编译器预定义宏分支
//   __AVX2__     -mavx2 编译时才定义（x86_64 可选扩展）
//   __SSE2__     x86_64 基线，必然定义
//   __ARM_NEON   AArch64 基线，必然定义
// ---------------------------------------------------------------------------
#if defined(__x86_64__) || defined(_M_X64)
#include <immintrin.h>
#define DEMO_ARCH_X86 1
#elif defined(__aarch64__)
#include <arm_neon.h>
#define DEMO_ARCH_ARM64 1
#endif

namespace {

constexpr char kPayload[] = "eks-multi-arch-demo-payload";
constexpr int kMaxIterations = 20'000'000;
constexpr int kMaxThreads = 64;
constexpr int kWarmupCap = 50'000;

std::string architecture() {
#if defined(__aarch64__)
  return "arm64";
#elif defined(__x86_64__)
  return "amd64";
#else
  return "unknown";
#endif
}

std::string compilerVersion() {
#if defined(__clang__)
  return "clang " + std::string(__clang_version__);
#elif defined(__GNUC__)
  return "gcc " + std::to_string(__GNUC__) + "." + std::to_string(__GNUC_MINOR__);
#else
  return "unknown compiler";
#endif
}

const char *simdPathName();

std::string runtimeVersion() {
  std::ostringstream out;
  out << "C++" << (__cplusplus / 100 % 100) << " (" << compilerVersion() << ", "
      << OpenSSL_version(OPENSSL_VERSION_STRING) << ", " << architecture()
      << ", simd=" << simdPathName() << ")";
  return out.str();
}

// 每次迭代：sha256(payload || byte(i & 0xFF))，累加哈希首尾字节防止被优化掉。
//
// 两个性能关键点（OpenSSL 3.x 特有，写错会让 C++ 无端比 Go 慢好几倍）：
//   1. 用 EVP_MD_fetch 显式取一次算法并复用。如果每次循环把静态的 EVP_sha256()
//      传给 EVP_DigestInit_ex，OpenSSL 3 会在每次 init 时做一遍 provider 查找。
//   2. 循环里不调 EVP_MD_CTX_reset —— EVP_DigestInit_ex 本身就会重置摘要状态。
// 实测（c6a.xlarge 单线程，换机型后数量级关系不变）：正确写法 10.0M ops/s，
// 每次 reset + 静态 EVP_sha256() 只有 2.9M ops/s，legacy SHA256() 2.6M ops/s。
int64_t sha256Loop(int iterations) {
  // 每个线程各自 fetch 一次，避免跨线程共享带来的争用
  EVP_MD* md = EVP_MD_fetch(nullptr, "SHA2-256", nullptr);
  EVP_MD_CTX* ctx = EVP_MD_CTX_new();
  if (md == nullptr || ctx == nullptr) {
    if (ctx != nullptr) EVP_MD_CTX_free(ctx);
    if (md != nullptr) EVP_MD_free(md);
    return 0;
  }

  const size_t payloadLen = std::strlen(kPayload);
  std::vector<unsigned char> buffer(payloadLen + 1);
  std::memcpy(buffer.data(), kPayload, payloadLen);

  unsigned char digest[EVP_MAX_MD_SIZE];
  unsigned int digestLen = 0;
  int64_t checksum = 0;

  for (int i = 0; i < iterations; ++i) {
    buffer[payloadLen] = static_cast<unsigned char>(i & 0xFF);
    if (EVP_DigestInit_ex(ctx, md, nullptr) != 1 ||
        EVP_DigestUpdate(ctx, buffer.data(), buffer.size()) != 1 ||
        EVP_DigestFinal_ex(ctx, digest, &digestLen) != 1) {
      EVP_MD_CTX_free(ctx);
      EVP_MD_free(md);
      return 0;
    }
    checksum += digest[0] + digest[digestLen - 1];
  }

  EVP_MD_CTX_free(ctx);
  EVP_MD_free(md);
  return checksum;
}

// ===========================================================================
// SIMD 段：对 uint8 数组求和（u8 累加到 u64）
//
// 同一个函数用预编译宏分成三条路径，x86 与 arm64 各写一份 intrinsics，
// 另外保留标量实现既作为兜底，也用于校验 SIMD 结果是否正确。
//
// 选择"字节求和"这个负载的原因：足够简单，标量结果可以逐字节精确复现，
// 因此能在运行时断言 SIMD 与标量结果完全一致——跨架构移植 SIMD 代码时，
// 这种自校验比性能数字更重要。
// ===========================================================================

// 编译期确定的 SIMD 路径名，会写进 JSON 输出
const char *simdPathName() {
#if defined(__AVX2__)
  return "x86 AVX2 (256-bit)";
#elif defined(DEMO_ARCH_X86) && defined(__SSE2__)
  return "x86 SSE2 (128-bit)";
#elif defined(DEMO_ARCH_ARM64)
  return "arm64 NEON (128-bit)";
#else
  return "scalar (no SIMD available)";
#endif
}

// 标量参考实现：SIMD 路径的正确性基准
uint64_t sumBytesScalar(const uint8_t *data, size_t len) {
  uint64_t total = 0;
  for (size_t i = 0; i < len; ++i) {
    total += data[i];
  }
  return total;
}

uint64_t sumBytesSimd(const uint8_t *data, size_t len) {
#if defined(__AVX2__)
  // ---- x86 AVX2：一次处理 32 字节 ----
  // _mm256_sad_epu8 对 8 字节一组求绝对差之和，与零向量做 SAD 即得字节和
  uint64_t total = 0;
  const __m256i zero = _mm256_setzero_si256();
  __m256i acc = _mm256_setzero_si256();
  size_t i = 0;
  for (; i + 32 <= len; i += 32) {
    __m256i chunk = _mm256_loadu_si256(reinterpret_cast<const __m256i *>(data + i));
    acc = _mm256_add_epi64(acc, _mm256_sad_epu8(chunk, zero));
  }
  alignas(32) uint64_t lanes[4];
  _mm256_store_si256(reinterpret_cast<__m256i *>(lanes), acc);
  total = lanes[0] + lanes[1] + lanes[2] + lanes[3];
  total += sumBytesScalar(data + i, len - i);  // 处理尾部不足 32 字节的部分
  return total;

#elif defined(DEMO_ARCH_X86) && defined(__SSE2__)
  // ---- x86 SSE2：一次处理 16 字节 ----
  // _mm_sad_epu8 与零向量做 SAD，结果落在两个 64 位 lane 里
  uint64_t total = 0;
  const __m128i zero = _mm_setzero_si128();
  __m128i acc = _mm_setzero_si128();
  size_t i = 0;
  for (; i + 16 <= len; i += 16) {
    __m128i chunk = _mm_loadu_si128(reinterpret_cast<const __m128i *>(data + i));
    acc = _mm_add_epi64(acc, _mm_sad_epu8(chunk, zero));
  }
  alignas(16) uint64_t lanes[2];
  _mm_store_si128(reinterpret_cast<__m128i *>(lanes), acc);
  total = lanes[0] + lanes[1];
  total += sumBytesScalar(data + i, len - i);
  return total;

#elif defined(DEMO_ARCH_ARM64)
  // ---- arm64 NEON：一次处理 16 字节 ----
  // vpadalq_u8 把 u8 成对相加并累加进 u16 向量，配合定期归约避免溢出。
  //
  // 两处溢出边界，跨架构移植 SIMD 时最容易踩：
  //   1. 单个 u16 lane 每轮最多加 2*255=510，取 128 轮 → 128*510=65280 < 65536，安全
  //   2. 归约必须用 vaddlvq_u16（返回 uint32_t）而不是 vaddvq_u16（返回 uint16_t）：
  //      8 个 lane 合计最大 8*65280=522240，用 u16 版本会被静默截断。
  uint64_t total = 0;
  size_t i = 0;
  while (i + 16 <= len) {
    uint16x8_t acc16 = vdupq_n_u16(0);
    size_t rounds = 0;
    while (i + 16 <= len && rounds < 128) {
      uint8x16_t chunk = vld1q_u8(data + i);
      acc16 = vpadalq_u8(acc16, chunk);
      i += 16;
      ++rounds;
    }
    total += vaddlvq_u16(acc16);  // 宽化水平求和，结果为 uint32_t
  }
  total += sumBytesScalar(data + i, len - i);
  return total;

#else
  // ---- 其他架构：退回标量 ----
  return sumBytesScalar(data, len);
#endif
}

// SIMD vs 标量的对比测量，附带正确性校验
struct SimdReport {
  const char *path;
  uint64_t simdSum;
  uint64_t scalarSum;
  bool matches;
  double simdMillis;
  double scalarMillis;
  double bytesProcessed;
};

void fillBuffer(std::vector<uint8_t>& buffer) {
  for (size_t i = 0; i < buffer.size(); ++i) {
    buffer[i] = static_cast<uint8_t>((i * 31u + 7u) & 0xFFu);
  }
}

SimdReport benchSimd(size_t bufferBytes, int iterations) {
  std::vector<uint8_t> buffer(bufferBytes);

  // 两点防止编译器把测量循环优化掉（否则会量出几千 GiB/s 这种假数字）：
  //   1. 每轮改写一个字节，让结果不再是循环不变量，无法提升到循环外
  //   2. 累加每轮结果，让返回值真正被使用
  // 两条路径跑完全相同的输入序列（跑前各自重置 buffer），因此累加值必须逐位相等。
  auto measure = [&](bool useSimd) {
    fillBuffer(buffer);
    uint64_t acc = 0;
    const auto start = std::chrono::steady_clock::now();
    for (int i = 0; i < iterations; ++i) {
      buffer[static_cast<size_t>(i) % buffer.size()] = static_cast<uint8_t>(i & 0xFF);
      acc += useSimd ? sumBytesSimd(buffer.data(), buffer.size())
                     : sumBytesScalar(buffer.data(), buffer.size());
    }
    const double millis =
        std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now() - start).count();
    return std::pair<uint64_t, double>{acc, millis};
  };

  // 预热两条路径（结果丢弃）
  measure(true);
  measure(false);

  const auto simd = measure(true);
  const auto scalar = measure(false);

  SimdReport report;
  report.path = simdPathName();
  report.simdSum = simd.first;
  report.scalarSum = scalar.first;
  report.matches = (simd.first == scalar.first);
  report.simdMillis = simd.second;
  report.scalarMillis = scalar.second;
  report.bytesProcessed = static_cast<double>(bufferBytes) * iterations;
  return report;
}

int64_t runParallel(int threads, int iterations) {
  if (threads == 1) {
    return sha256Loop(iterations);
  }
  std::vector<int64_t> checksums(static_cast<size_t>(threads), 0);
  std::vector<std::thread> workers;
  workers.reserve(static_cast<size_t>(threads));
  for (int i = 0; i < threads; ++i) {
    workers.emplace_back([i, iterations, &checksums]() {
      checksums[static_cast<size_t>(i)] = sha256Loop(iterations);
    });
  }
  for (auto& worker : workers) {
    worker.join();
  }
  int64_t total = 0;
  for (int64_t c : checksums) {
    total += c;
  }
  return total;
}

void printError(const std::string& message) {
  std::cout << "{\"error\":\"" << message << "\"}" << std::endl;
}

}  // namespace

int main(int argc, char** argv) {
  int iterations = 2'000'000;
  int threads = 1;
  bool simdMode = false;
  size_t simdBufferBytes = 1 << 20;  // 1 MiB
  int simdIterations = 200;

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--version") {
      std::cout << runtimeVersion() << std::endl;
      return 0;
    }
    if (arg == "--simd-path") {
      std::cout << simdPathName() << std::endl;
      return 0;
    }
    if (arg == "--simd") {
      simdMode = true;
      continue;
    }
    if (arg == "--simd-bytes" && i + 1 < argc) {
      try {
        simdBufferBytes = static_cast<size_t>(std::stoul(argv[++i]));
      } catch (const std::exception&) {
        printError("参数必须是整数：--simd-bytes");
        return 2;
      }
      continue;
    }
    if (arg == "--simd-iterations" && i + 1 < argc) {
      try {
        simdIterations = std::stoi(argv[++i]);
      } catch (const std::exception&) {
        printError("参数必须是整数：--simd-iterations");
        return 2;
      }
      continue;
    }
    if ((arg == "--iterations" || arg == "--threads") && i + 1 < argc) {
      try {
        const int value = std::stoi(argv[++i]);
        if (arg == "--iterations") {
          iterations = value;
        } else {
          threads = value;
        }
      } catch (const std::exception&) {
        printError("参数必须是整数：" + arg);
        return 2;
      }
    }
  }

  if (iterations < 1 || iterations > kMaxIterations) {
    printError("iterations 必须在 1 和 " + std::to_string(kMaxIterations) + " 之间");
    return 2;
  }
  if (threads < 1 || threads > kMaxThreads) {
    printError("threads 必须在 1 和 " + std::to_string(kMaxThreads) + " 之间");
    return 2;
  }

  // ---- SIMD 模式：只跑 SIMD vs 标量的对比 ----
  if (simdMode) {
    if (simdBufferBytes < 64 || simdBufferBytes > (64u << 20)) {
      printError("simd-bytes 必须在 64 和 67108864 之间");
      return 2;
    }
    if (simdIterations < 1 || simdIterations > 100000) {
      printError("simd-iterations 必须在 1 和 100000 之间");
      return 2;
    }
    const SimdReport r = benchSimd(simdBufferBytes, simdIterations);
    const double simdGiBps =
        r.simdMillis > 0 ? r.bytesProcessed / (r.simdMillis / 1000.0) / (1024.0 * 1024 * 1024) : 0.0;
    const double scalarGiBps =
        r.scalarMillis > 0 ? r.bytesProcessed / (r.scalarMillis / 1000.0) / (1024.0 * 1024 * 1024) : 0.0;
    std::printf(
        "{\"lang\":\"cpp\",\"mode\":\"simd\",\"runtime\":\"%s\","
        "\"simdPath\":\"%s\",\"bufferBytes\":%zu,\"iterations\":%d,"
        "\"simdMillis\":%.2f,\"scalarMillis\":%.2f,"
        "\"simdGiBPerSecond\":%.2f,\"scalarGiBPerSecond\":%.2f,\"speedup\":%.2f,"
        "\"simdSum\":%llu,\"scalarSum\":%llu,\"resultsMatch\":%s,"
        "\"note\":\"同一份源码用预编译宏分支：x86 走 SSE2/AVX2，arm64 走 NEON\"}\n",
        runtimeVersion().c_str(), r.path, simdBufferBytes, simdIterations,
        r.simdMillis, r.scalarMillis, simdGiBps, scalarGiBps,
        r.scalarMillis > 0 ? r.scalarMillis / r.simdMillis : 0.0,
        static_cast<unsigned long long>(r.simdSum),
        static_cast<unsigned long long>(r.scalarSum),
        r.matches ? "true" : "false");
    return r.matches ? 0 : 1;
  }

  // 预热，口径与其他语言一致
  runParallel(threads, std::min(iterations, kWarmupCap));

  const auto start = std::chrono::steady_clock::now();
  const int64_t checksum = runParallel(threads, iterations);
  const auto elapsed = std::chrono::steady_clock::now() - start;

  const double elapsedMillis =
      std::chrono::duration<double, std::milli>(elapsed).count();
  const double seconds = elapsedMillis / 1000.0;
  const int64_t total = static_cast<int64_t>(iterations) * threads;
  const int64_t aggregate =
      seconds > 0 ? static_cast<int64_t>(static_cast<double>(total) / seconds) : 0;

  std::printf(
      "{\"lang\":\"cpp\",\"runtime\":\"%s\",\"mode\":\"%s\",\"threads\":%d,"
      "\"iterationsPerThread\":%d,\"totalIterations\":%lld,"
      "\"elapsedMillis\":%.2f,\"opsPerSecond\":%lld,"
      "\"opsPerSecondPerThread\":%lld,\"checksum\":%lld,"
      "\"note\":\"std::thread, OpenSSL EVP SHA-256\"}\n",
      runtimeVersion().c_str(), threads == 1 ? "single-thread" : "multi-thread",
      threads, iterations, static_cast<long long>(total), elapsedMillis,
      static_cast<long long>(aggregate),
      static_cast<long long>(threads > 0 ? aggregate / threads : 0),
      static_cast<long long>(checksum));
  return 0;
}
