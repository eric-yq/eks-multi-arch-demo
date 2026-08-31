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
#include <vector>

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

std::string runtimeVersion() {
  std::ostringstream out;
  out << "C++" << (__cplusplus / 100 % 100) << " (" << compilerVersion() << ", "
      << OpenSSL_version(OPENSSL_VERSION_STRING) << ", " << architecture() << ")";
  return out.str();
}

// 每次迭代：sha256(payload || byte(i & 0xFF))，累加哈希首尾字节防止被优化掉。
//
// 两个性能关键点（OpenSSL 3.x 特有，写错会让 C++ 无端比 Go 慢好几倍）：
//   1. 用 EVP_MD_fetch 显式取一次算法并复用。如果每次循环把静态的 EVP_sha256()
//      传给 EVP_DigestInit_ex，OpenSSL 3 会在每次 init 时做一遍 provider 查找。
//   2. 循环里不调 EVP_MD_CTX_reset —— EVP_DigestInit_ex 本身就会重置摘要状态。
// 实测（同一台 c6a.xlarge 单线程）：正确写法 10.0M ops/s，
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

  for (int i = 1; i < argc; ++i) {
    const std::string arg = argv[i];
    if (arg == "--version") {
      std::cout << runtimeVersion() << std::endl;
      return 0;
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
