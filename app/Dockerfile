# syntax=docker/dockerfile:1
#
# 多架构镜像：把上一步构建出来的 jar 包（架构无关的字节码）分别打进
# linux/amd64 与 linux/arm64 两个镜像，再由 buildx 生成一个 manifest list。
#
# 关键点：本 Dockerfile 只有 FROM / COPY / ENV 等指令，没有任何需要在目标架构上
# 执行的 RUN 指令，因此在 x86 机器上交叉构建 arm64 镜像时无需 QEMU 模拟，速度很快。
#
# 构建（单条命令产出 manifest list 并推送到 ECR）：
#   docker buildx build --platform linux/amd64,linux/arm64 \
#     -t <account>.dkr.ecr.<region>.amazonaws.com/java-arch-demo:1.0.0 --push .

# Amazon Corretto 21（Amazon Linux 2023），官方同时提供 amd64 与 arm64 manifest
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023-headless

# buildx 自动注入的构建参数，用于把目标架构写进镜像标签/环境变量
ARG TARGETPLATFORM
ARG TARGETARCH
ARG APP_VERSION=1.0.0
ARG JAR_FILE=target/java-arch-demo.jar

LABEL org.opencontainers.image.title="java-arch-demo" \
      org.opencontainers.image.description="Multi-arch (amd64/arm64) Java demo for Amazon EKS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      demo.build.target-platform="${TARGETPLATFORM}"

WORKDIR /app

# 同一个 jar，两种架构复用
COPY ${JAR_FILE} /app/app.jar

# 以非 root 身份运行。这里直接使用数字 UID，避免引入 RUN useradd，
# 保证跨架构构建不需要模拟执行。
USER 10001

EXPOSE 8080

# 容器感知的 JVM 参数：按 cgroup 内存上限分配堆
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError -Djava.security.egd=file:/dev/./urandom"
ENV TARGET_PLATFORM="${TARGETPLATFORM}"
ENV TARGET_ARCH="${TARGETARCH}"

# exec 形式启动，保证 java 进程是 PID 1，能正确接收 SIGTERM 完成优雅停机
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
