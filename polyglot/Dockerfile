# syntax=docker/dockerfile:1
#
# 多语言（Go / Python / C++）单镜像。与 Java 服务的关键区别：
#
#   Java   : jar 是架构无关的字节码，一份产物两种架构通吃
#   Python : 源码解释执行，同样与架构无关
#   Go/C++ : 编译成原生机器码，**必须按架构分别编译**
#
# 因此本镜像采用"在对应架构的实例上原生构建"的方式：
#   在 x86 实例上   docker build → 推 <repo>:<tag>-amd64
#   在 Graviton 上  docker build → 推 <repo>:<tag>-arm64
#   任意一台机器上  合并两个 tag → <repo>:<tag>（manifest list）
#
# 这个 Dockerfile 刻意**不写 --platform / GOARCH 交叉编译**：
#   - 编译阶段跑在本机架构上，是真正的原生编译，不需要 QEMU，也没有模拟带来的性能损失
#   - buildx 插件也不需要（普通 docker build 即可）
# 构建脚本：scripts/07a-build-push-polyglot-native.sh（每种架构各跑一次）
#          scripts/07b-create-polyglot-manifest.sh（合并）

# ---------------- 1) Go：原生编译静态二进制 ----------------
FROM public.ecr.aws/docker/library/golang:1.27-bookworm AS go-builder
WORKDIR /src
COPY go/go.mod ./
RUN go mod download
COPY go/ ./
# CGO_ENABLED=0：纯静态，不依赖运行镜像里的 libc 版本
RUN set -eux; \
    echo "Go 构建架构：$(uname -m)"; \
    mkdir -p /out; \
    CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o /out/polyglot-server .; \
    go version

# ---------------- 2) C++：原生编译，链接 OpenSSL ----------------
# 用 python:3.13-bookworm 作为构建镜像：它自带 g++ 与 OpenSSL 头文件，
# 不需要 apt-get；而且和运行镜像 python:3.13-slim 同属 bookworm，
# libcrypto ABI 一致（另外再静态链 libstdc++/libgcc 做双重保险）。
FROM public.ecr.aws/docker/library/python:3.13-bookworm AS cpp-builder
WORKDIR /src
COPY cpp/bench.cpp ./
RUN set -eux; \
    echo "C++ 构建架构：$(uname -m)"; \
    mkdir -p /out; \
    g++ -O2 -std=c++17 -pthread -static-libstdc++ -static-libgcc \
        -o /out/bench-cpp bench.cpp -lcrypto; \
    /out/bench-cpp --version

# ---------------- 3) 运行镜像 ----------------
# 只有 COPY，没有 RUN：镜像体积小，且不依赖构建机的任何环境
FROM public.ecr.aws/docker/library/python:3.13-slim

ARG APP_VERSION=dev
ARG BUILD_ARCH=unknown

LABEL org.opencontainers.image.title="polyglot-arch-demo" \
      org.opencontainers.image.description="Go + Python + C++ multi-arch demo for Amazon EKS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      demo.build.arch="${BUILD_ARCH}" \
      demo.languages="go,python,cpp"

WORKDIR /app

COPY --from=go-builder  /out/polyglot-server /app/polyglot-server
COPY --from=cpp-builder /out/bench-cpp       /app/bench-cpp
COPY python/bench.py                         /app/bench.py

# 非 root 运行；数字 UID 无需 useradd
USER 10001

EXPOSE 8080

ENV APP_VERSION="${APP_VERSION}" \
    TARGET_PLATFORM="linux/${BUILD_ARCH}" \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1

# Go 进程作为 PID 1，能正确接收 SIGTERM
ENTRYPOINT ["/app/polyglot-server"]
