# syntax=docker/dockerfile:1
#
# Java 服务镜像。注意：**引入 JNI 之后这个镜像不再是"纯架构无关"的了。**
#
# 各部分产物的架构属性：
#   jar                     架构无关（字节码），一份通吃
#   lz4-java 的原生 .so     第三方依赖自带各架构版本（linux/amd64、linux/aarch64），无需我们处理
#   libarchdemo_native.so   自研 C 库，**必须为每种架构分别编译**  ← 新增的约束
#
# 因此构建方式有两条路：
#   A. 单机交叉构建（scripts/03-build-push-image.sh）
#      native-builder 阶段要在目标架构下执行，跨架构时依赖 QEMU 模拟，脚本会检查 binfmt。
#   B. 各架构原生构建（scripts/03a + 03b，推荐）
#      在 x86 与 Graviton 实例上各构建一次再合并 manifest list，不需要 QEMU，速度也快。

# ---------------- 1) 编译自研 C 库（JNI）----------------
# 用完整版 Corretto：它带 $JAVA_HOME/include/jni.h；且与运行镜像同为 AL2023，
# glibc 版本一致（2.34），编出来的 .so 能直接在运行镜像里加载。
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023 AS native-builder

RUN dnf install -y gcc && dnf clean all

WORKDIR /src
COPY native/ ./native/

# 纯标量编译：不加 -march/-mtune 之类架构特定优化，同一份源码两种架构都能编
RUN set -eux; \
    echo "JNI 库构建架构：$(uname -m)"; \
    mkdir -p /out/lib; \
    gcc -O2 -fPIC -shared -Wall -Wextra \
        -I"${JAVA_HOME}/include" -I"${JAVA_HOME}/include/linux" \
        -o /out/lib/libarchdemo_native.so \
        native/archdemo_native.c native/archdemo_jni.c; \
    ls -l /out/lib/libarchdemo_native.so

# ---------------- 2) 运行镜像 ----------------
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023-headless

ARG TARGETPLATFORM
ARG TARGETARCH
ARG APP_VERSION=1.0.0
ARG JAR_FILE=target/java-arch-demo.jar

LABEL org.opencontainers.image.title="java-arch-demo" \
      org.opencontainers.image.description="Multi-arch (amd64/arm64) Java demo for Amazon EKS" \
      org.opencontainers.image.version="${APP_VERSION}" \
      demo.build.target-platform="${TARGETPLATFORM}" \
      demo.native.libs="libarchdemo_native.so (JNI), lz4-java bundled .so"

WORKDIR /app

# 架构无关的 jar
COPY ${JAR_FILE} /app/app.jar
# 按架构编译出来的自研 .so
COPY --from=native-builder /out/lib/libarchdemo_native.so /app/lib/

# 以非 root 身份运行（数字 UID，避免引入 RUN useradd）
USER 10001

EXPOSE 8080

# java.library.path 指向 .so 所在目录，供 System.loadLibrary("archdemo_native") 使用
ENV JAVA_OPTS="-XX:MaxRAMPercentage=75.0 -XX:InitialRAMPercentage=50.0 -XX:+UseG1GC -XX:+ExitOnOutOfMemoryError -Djava.security.egd=file:/dev/./urandom -Djava.library.path=/app/lib"
ENV TARGET_PLATFORM="${TARGETPLATFORM}"
ENV TARGET_ARCH="${TARGETARCH}"

# exec 形式启动，保证 java 进程是 PID 1，能正确接收 SIGTERM 完成优雅停机
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
