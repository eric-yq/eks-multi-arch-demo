#!/usr/bin/env bash
# 步骤 2：构建 Java 应用的 jar 包
#
# jar 里是与 CPU 架构无关的字节码，因此一次构建即可同时用于 amd64 与 arm64 镜像。
# 优先使用本机 JDK 21+；没有则回退到容器内构建（maven:3.9-amazoncorretto-21）。
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/env.sh"

cd "${APP_DIR}"

if JDK21="$(find_jdk21)"; then
  log "使用本机 JDK：${JDK21}"
  need mvn
  JAVA_HOME="${JDK21}" mvn -B -DskipTests clean package
else
  warn "未找到 JDK 21+，改用容器内构建"
  need docker
  docker run --rm \
    -v "${APP_DIR}:/workspace" \
    -v "${HOME}/.m2:/root/.m2" \
    -w /workspace \
    public.ecr.aws/docker/library/maven:3.9-amazoncorretto-21 \
    mvn -B -DskipTests clean package
fi

JAR_PATH="${APP_DIR}/target/${JAR_NAME}"
[[ -f "${JAR_PATH}" ]] || die "未找到 jar：${JAR_PATH}"

log "构建完成：${JAR_PATH} ($(du -h "${JAR_PATH}" | cut -f1))"
log "本机快速验证（可选）：java -jar app/target/${JAR_NAME} 然后访问 http://localhost:8080/api/info"
log "下一步：./scripts/03-build-push-image.sh"
