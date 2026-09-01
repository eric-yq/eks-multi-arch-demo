# EKS 多架构（x86 + Graviton）Java Demo

演示的是一条**迁移路径**，而不是一个一开始就多架构的集群：

> 客户现状：EKS 集群里全是 x86 节点，Java 服务跑在 x86 上。
> 演示动作：**新增一个 Graviton 节点组**，用**完全相同的镜像 tag** 把服务也部署上去，
> 存量集群、Service、镜像地址都不动。

| 阶段 | 集群状态 | 对应步骤 |
| --- | --- | --- |
| 改造前 | 1 个节点组 `ng-x86-c7i`：1 × `c7i.xlarge`（Intel Sapphire Rapids / x86_64），服务只跑在 x86 | 步骤 1 → 4 |
| 改造后 | 增加 `ng-graviton-c9g`：1 × `c9g.xlarge`（Graviton5 / ARM64），同一个镜像同时跑在两种架构上 | 步骤 6 |

| 组成 | 说明 |
| --- | --- |
| EKS 集群 | `multi-arch-demo`，Kubernetes 1.36，us-east-1 |
| Java 应用 | Spring Boot 3.5.16 + Java 21，含 lz4 第三方原生依赖与自研 JNI 库 |
| 多语言应用 | Go + Python + C++ 单镜像，含 CGO 原生库与按架构分支的 SIMD 代码 |
| 镜像 | 单个 tag 的 manifest list，同时包含 `linux/amd64` 与 `linux/arm64` |
| 部署 | 两个 Deployment 只有 `nodeSelector: kubernetes.io/arch` 一处不同，一个 Service 统一入口 |

两个服务合起来覆盖了 Graviton 迁移中原生依赖的四种典型情况：

| 情况 | 例子 | 迁移工作量 |
| --- | --- | --- |
| 架构无关产物 | Java 的 jar、Python 的 .py | 零 |
| 第三方依赖自带各架构原生库 | `lz4-java`（jar 内含 amd64/aarch64 的 .so） | 零，但要逐个确认上游是否提供 |
| 自研原生库 | Java 的 JNI `.so`、Go 经 CGO 调用的 `.so` | 必须按架构各编译一次 |
| 架构特定指令集代码 | C++ 的 SIMD（x86 SSE2/AVX2 vs arm64 NEON） | 要为每种架构分别实现并校验结果一致 |

## 目录结构

```
.
├── infra/
│   ├── cluster.yaml                # 步骤 1：集群 + 唯一的 x86 节点组
│   └── nodegroup-c9g.yaml          # 步骤 6：增量添加的 Graviton5 节点组（只含节点组）
├── app/                            # Java 应用
│   ├── pom.xml                     # 含 lz4-java 依赖（jar 内置各架构 .so）
│   ├── Dockerfile                  # 含 native-builder 阶段：编译 JNI 的 .so
│   ├── native/                     # 自研 C 库（纯标量，无 SIMD）+ JNI 桥接
│   │   ├── archdemo_native.c/.h
│   │   └── archdemo_jni.c
│   └── src/main/java/com/example/archdemo/
│       ├── ArchDemoApplication.java
│       ├── ArchInfoService.java    # 采集 os.arch / JVM / Pod / Node / 原生依赖信息
│       ├── ArchInfoController.java # GET /  与  GET /api/info
│       ├── BenchmarkController.java# GET /api/bench  简易 CPU 对比
│       ├── Lz4Service.java         # lz4 压缩/解压往返与吞吐
│       ├── NativeLib.java          # JNI 绑定，加载 libarchdemo_native.so
│       └── NativeDepsController.java # GET /api/compress、GET /api/native
├── polyglot/                       # 第二个 demo 服务：Go + Python + C++ 单镜像
│   ├── Dockerfile                  # 原生多阶段构建（每种架构各构建一次，无需 QEMU）
│   ├── go/                         # HTTP 前门 + Go 压测 + cgroup CPU 识别
│   │   └── native_cgo.go           # CGO 绑定，链接 libgodemo_native.so
│   ├── cgo/                        # 自研 C 库（纯标量，无 SIMD），供 Go 调用
│   ├── python/bench.py             # Python 压测（多进程绕开 GIL）
│   └── cpp/bench.cpp               # C++ 压测 + 按架构分支的 SIMD（SSE2/AVX2/NEON）
├── k8s/
│   ├── 00-namespace.yaml
│   ├── deployment-amd64.yaml       # 步骤 4：nodeSelector kubernetes.io/arch=amd64
│   ├── deployment-arm64.yaml       # 步骤 6：nodeSelector kubernetes.io/arch=arm64
│   ├── deployment-mixed.yaml       # 进阶：一个 Deployment 跨两种架构均匀分布
│   ├── service.yaml                # ClusterIP，同时选中两组 Pod
│   ├── service-nlb.yaml            # 可选：对外暴露（会创建 NLB）
│   └── polyglot/                   # 多语言服务的 Deployment 与 Service
└── scripts/
    ├── env.sh                      # 共享变量与工具函数（AWS_REGION / CLUSTER_NAME / IMAGE_TAG ...）
    ├── 01-create-cluster.sh
    ├── 02-build-jar.sh
    ├── 03-build-push-image.sh      # 方式 A：一台机器交叉构建两种架构
    ├── 03a-build-push-native.sh    # 方式 B：在当前实例上原生构建单架构并推送
    ├── 03b-create-manifest-list.sh # 方式 B：把两个单架构 tag 合并成多架构 tag
    ├── 04a-deploy-java-amd64.sh    # 部署 Java 到 x86 节点组
    ├── 04b-deploy-java-arm64.sh    # 部署 Java 到 Graviton 节点组（需先跑 06）
    ├── 05-verify.sh                # 任何阶段都可以跑，自动发现已部署的分组
    ├── 06-add-c9g-nodegroup.sh     # 增量：只加 Graviton 节点组（不动业务）
    ├── 07a-build-push-polyglot-native.sh  # 多语言镜像：在本机架构上原生构建并推送
    ├── 07b-create-polyglot-manifest.sh    # 多语言镜像：合并成多架构 tag
    ├── 08a-deploy-polyglot-amd64.sh # 多语言服务：部署到 x86
    ├── 08b-deploy-polyglot-arm64.sh # 多语言服务：部署到 Graviton
    ├── 09-verify-polyglot.sh       # 多语言服务：三语言 × 两架构 压测对比
    └── 90-cleanup.sh

bench/                              # 独立工具：容器启动耗时基准，见 bench/README.md
```

## 前置条件

需要的命令：`aws`（已配置凭证）、`eksctl`、`kubectl`、`docker`（含 `buildx` 插件）、`mvn` + JDK 21。

```bash
aws sts get-caller-identity     # 确认凭证
eksctl version                  # >= 0.200 建议
docker buildx version           # 缺失时见下方“buildx 安装”
```

buildx 安装（多架构构建必需）：

```bash
mkdir -p ~/.docker/cli-plugins
curl -sSL -o ~/.docker/cli-plugins/docker-buildx \
  https://github.com/docker/buildx/releases/download/v0.36.1/buildx-v0.36.1.linux-amd64
chmod +x ~/.docker/cli-plugins/docker-buildx
```

费用提示（us-east-1 按需价格，已核对 AWS Pricing API）：EKS 控制平面 **$0.10/小时**，
`c7i.xlarge` **$0.1785/小时**，`c9g.xlarge` **$0.17388/小时**（Graviton5 比同规格 x86 便宜约 2.6%），
另有 NAT 网关、EBS 与数据传输费用。**用完请执行清理步骤。**

所有脚本的参数都可用环境变量覆盖，例如：

```bash
export AWS_REGION=ap-southeast-1     # 换区域时脚本会自动去掉硬编码的可用区
export CLUSTER_NAME=my-demo
export IMAGE_TAG=1.0.1
```

---

## 步骤 1：创建 EKS 集群（只有一个 x86 节点组）

```bash
./scripts/01-create-cluster.sh
# 等价于：eksctl create cluster -f infra/cluster.yaml
```

耗时约 15~20 分钟。这一步刻意**只建一个 x86 节点组**，用来代表客户的存量集群：

```yaml
managedNodeGroups:
  - name: ng-x86-c7i
    amiFamily: AmazonLinux2023
    instanceType: c7i.xlarge      # x86_64
    desiredCapacity: 1
```

Graviton 节点组不在这个文件里，而是单独放在 `infra/nodegroup-c9g.yaml`，由步骤 6 添加。
必须分成两个文件：`eksctl create cluster` 没有 `--include` 过滤节点组，写在一起的话建集群时就会
把 Graviton 节点一并建出来，"先只有 x86"的前提就没了。

验证：

```bash
kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup
```

预期只看到 1 个节点，`ARCH=amd64`、`INSTANCE-TYPE=c7i.xlarge`。

## 步骤 2：构建 Java 应用的 jar

```bash
./scripts/02-build-jar.sh
# 产物：app/target/java-arch-demo.jar
```

脚本优先用本机 JDK 21+，找不到就自动回退到容器内构建（`maven:3.9-amazoncorretto-21`）。

应用接口：

| 路径 | 用途 |
| --- | --- |
| `GET /` | 纯文本汇总：CPU 架构、JVM、Pod、Node、节点组、实例类型、原生依赖 |
| `GET /api/info` | 同样的信息，JSON 格式，便于脚本统计架构分布 |
| `GET /api/bench?iterations=2000000&threads=4` | SHA-256 循环，单核/多核两种口径 |
| `GET /api/compress?sizeBytes=262144&iterations=30&threads=4` | lz4 压缩/解压，多线程聚合吞吐 |
| `GET /api/native?iterations=20000&sizeBytes=4096&threads=4` | 自研 JNI 库 crc32 / fnv1a，多线程聚合吞吐 |
| `GET /api/compress?sizeBytes=262144&iterations=50` | lz4 压缩/解压往返、压缩率、吞吐 |
| `GET /api/native?iterations=20000&sizeBytes=4096` | 经 JNI 调用自研 C 库（CRC-32 / FNV-1a） |
| `GET /actuator/health/{liveness,readiness}` | 给 k8s 探针用 |

两个原生依赖接口的看点（下列数字实测于**上一版机型** c6a.xlarge 容器内，换成 c7i 后需重测）：

```
/api/compress  implementation=LZ4Factory:JNI  usingNativeSo=true
               压缩 6125 MiB/s  解压 11782 MiB/s  压缩率 48.44  往返校验通过
/api/native    nativeInfo=archdemo_native 1.0 (gcc 11.5.0, amd64, scalar/no-simd)
               nativeArch=amd64  archMatchesJvm=true
```

`archMatchesJvm` 是关键断言：`.so` 的编译期宏与 JVM 的 `os.arch` 一致，
才能证明加载到的是当前架构的库，而不是碰巧能跑起来。

两个接口都支持 `threads` 参数（不传 = 容器可见 vCPU 数），吞吐是多线程聚合值。
压缩与解压拆成两个独立的并行阶段分别计时——在一个循环里交替做两件事的话，
墙钟时间无法归给某个方向，聚合吞吐会算错。`05-verify.sh` 第 6 步默认按多核跑，
因为单核口径会系统性低估 Graviton（核多、每核便宜是它的主要优势来源）。

> **lz4 有个坑值得单独讲。** `LZ4Factory.fastestInstance()` 在 Spring Boot fat jar 下
> **不会**选 JNI 实现：lz4-java 要求 `Native` 类由 system classloader 加载，而 fat jar 用的是
> `LaunchedClassLoader`，条件不满足就静默退回纯 Java 实现。实测差距很大——
> 显式调用 `nativeInstance()` 压缩 6125 MiB/s，退回纯 Java 只有 404 MiB/s（15 倍）。
> 接口里同时输出 `implementation` 与 `fastestInstanceWouldPick` 两个字段，方便现场对比。

本机快速试跑：

```bash
java -jar app/target/java-arch-demo.jar
curl -s localhost:8080/api/info | jq .architecture
```

## 步骤 3：把 jar 打成多架构镜像并推送到 ECR

两种方式，产物完全等价（同一个 tag 下的 manifest list），按需选一个：

| | 方式 A：单机交叉构建 | 方式 B：两台机器分别原生构建 |
| --- | --- | --- |
| 脚本 | `03-build-push-image.sh` | `03a-build-push-native.sh` ×2 + `03b-create-manifest-list.sh` |
| 机器 | 1 台（x86 或 Graviton 都行） | 2 台：x86 + Graviton |
| 依赖 | buildx（`docker-container` 驱动） | 只要 `docker build` / `docker push` |
| 适用 | 本 demo 这种「只 COPY jar」的镜像 | Dockerfile 里有 `RUN` 且需要编译原生依赖时 |

### 方式 A：一台机器构建两种架构（默认）

```bash
./scripts/03-build-push-image.sh
```

脚本做四件事：创建 ECR 仓库（幂等）→ 登录 ECR → 创建 `docker-container` 驱动的 buildx builder →
一条命令构建并推送两种架构。核心命令：

```bash
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  --provenance=false \
  -t <account>.dkr.ecr.<region>.amazonaws.com/java-arch-demo:1.0.0 \
  --push app/
```

**jar 是架构无关的，但这个镜像已经不是了。** 自从引入 JNI 原生库之后，镜像里有三类产物：

| 产物 | 架构属性 |
| --- | --- |
| `app.jar` | 架构无关字节码，一份通吃 |
| lz4-java 的 `liblz4-java.so` | 第三方依赖自带 amd64/aarch64，运行时按架构解压加载 |
| `libarchdemo_native.so` | **自研，必须为每种架构分别编译** |

所以 `app/Dockerfile` 多了一个 `native-builder` 阶段：

```dockerfile
# 用完整版 Corretto：有 jni.h，且与运行镜像同为 AL2023（glibc 2.34），编出的 .so 能直接加载
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023 AS native-builder
RUN dnf install -y gcc && dnf clean all
RUN gcc -O2 -fPIC -shared -I"$JAVA_HOME/include" -I"$JAVA_HOME/include/linux" \
        -o /out/lib/libarchdemo_native.so native/archdemo_native.c native/archdemo_jni.c
```

这个 `RUN` 必须在目标架构下执行，于是**单机交叉构建（方式 A）现在需要 QEMU**，
`03-build-push-image.sh` 会先检查 binfmt handler，缺少时直接中止并提示两个选项。
想完全避开模拟就用方式 B（03a + 03b 各架构原生构建）。

校验镜像是一个 manifest list：

```bash
docker buildx imagetools inspect <account>.dkr.ecr.<region>.amazonaws.com/java-arch-demo:1.0.0
# 应输出两条 Platform：linux/amd64 与 linux/arm64
```

### 方式 B：在 x86 与 Graviton 实例上分别原生构建

思路是「两次单架构构建 + 一次 manifest 合并」：各自推送带架构后缀的 tag，再把两个 tag 合并成一个
多架构 tag。合并只改 registry 里的 manifest，不重新构建、不上传镜像层，几秒钟完成。

```
x86 实例      docker build → push  <repo>:1.0.0-amd64  ┐
                                                        ├─→ 合并 → <repo>:1.0.0（manifest list）
Graviton 实例 docker build → push  <repo>:1.0.0-arm64  ┘
```

在 **x86 实例**（例如 c7i.xlarge）上：

```bash
git clone <this-repo> && cd eks-multi-arch-demo
./scripts/02-build-jar.sh                 # 或从别处 scp 现成的 jar，jar 与架构无关
./scripts/03a-build-push-native.sh        # 自动识别 uname -m → 推送 <repo>:1.0.0-amd64
```

在 **Graviton 实例**（例如 c6g.xlarge）上执行同样两条命令，脚本会自动推送 `<repo>:1.0.0-arm64`。

两边都推送完成后，在任意一台上合并：

```bash
./scripts/03b-create-manifest-list.sh
# 等价命令（buildx 版）：
#   docker buildx imagetools create -t <repo>:1.0.0 <repo>:1.0.0-amd64 <repo>:1.0.0-arm64
# 没有 buildx 时脚本自动改用：
#   docker manifest create <repo>:1.0.0 --amend <repo>:1.0.0-amd64 --amend <repo>:1.0.0-arm64
#   docker manifest push   <repo>:1.0.0
```

`03b` 会先检查两个单架构 tag 是否都已存在，缺哪个就报错提示去对应架构的机器上构建，
合并完再打印 manifest list 校验结果。之后的部署与验证脚本完全不变。

几个实用开关：

```bash
IMAGE_TAG=1.0.1 ./scripts/03a-build-push-native.sh          # 换版本号
TARGET_ARCH=arm64 ./scripts/03a-build-push-native.sh         # 强制目标架构（与本机不同时退化为交叉构建，会提示）
IMAGE_URI=my-registry:5000/java-arch-demo:1.0.0 \
  INSECURE_REGISTRY=true ./scripts/03b-create-manifest-list.sh   # 用自建 registry（非 ECR 时自动跳过 ECR 登录）
```

两台机器的准备工作：都需要 `docker` + AWS 凭证（能 push 到同一个 ECR 仓库），
以及 JDK 21 或可用的 docker（`02-build-jar.sh` 会自动回退到容器内构建，
`maven:3.9-amazoncorretto-21` 同时提供 amd64 与 arm64）。ECR 仓库由先跑的那台机器创建，脚本是幂等的。

> 注意：**不要**两台机器都推送同一个 `:1.0.0` tag。后推的会覆盖先推的，
> 最终 tag 只剩单一架构，另一种架构的节点会以 `no match for platform` 拉取失败。
> 架构后缀 + manifest 合并就是为了避免这个坑。

## 步骤 4：部署 Java 服务（按架构拆成两个脚本）

| 脚本 | 作用 | 前提 |
| --- | --- | --- |
| `04a-deploy-java-amd64.sh` | 部署到 x86 节点组 | 步骤 1 建好的 x86 节点组 |
| `04b-deploy-java-arm64.sh` | 部署到 Graviton 节点组 | 先跑步骤 6 加好 Graviton 节点组 |

演示"改造前"的状态只跑 04a：

```bash
./scripts/04a-deploy-java-amd64.sh
```

它部署 `deployment-amd64.yaml` 与 `service.yaml`，此时集群里也只有 x86 节点：

```yaml
# k8s/deployment-amd64.yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64      # 落在 c7i.xlarge
```

`kubernetes.io/arch` 是 kubelet 自动打的标签，不需要自定义。

手工执行等价命令：

```bash
IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/java-arch-demo:1.0.0
kubectl apply -f k8s/00-namespace.yaml
for f in deployment-amd64.yaml service.yaml; do
  sed "s|IMAGE_PLACEHOLDER|$IMAGE|g" k8s/$f | kubectl apply -f -
done
kubectl -n demo rollout status deploy/java-arch-demo-amd64
```

跑一次 `./scripts/05-verify.sh` 可以把"改造前"的状态留档：只有一组 amd64 Pod。
Graviton 部分在步骤 6。

其他常见的架构调度方式（步骤 6 之后按需选用）：

- `nodeAffinity` + `In [amd64, arm64]`：允许两种架构，配合 `topologySpreadConstraints`
  按 `topologyKey: kubernetes.io/arch` 均匀分布，见 `k8s/deployment-mixed.yaml`；
  存量 x86 服务灰度迁移到 Graviton 时常用这种写法。
- 给 Graviton 节点组加 `taints`，只有显式 `tolerations` 的负载才会调度过去。
- 直接用节点组标签（本 demo 的节点组还带了 `demo.arch=amd64` / `demo.arch=arm64`）
  或 `eks.amazonaws.com/nodegroup` 精确指定节点组。

## 步骤 5：验证

```bash
./scripts/05-verify.sh
```

脚本依次输出：节点架构表 → Pod 落点（含节点真实架构与实例类型）→ 每个 Pod 容器内 `uname -m` →
通过 Service 采样 12 次的架构/实例类型分布 → **自动发现所有部署分组**并逐组做 `/api/bench` 对比：

步骤 4 之后跑只有 `amd64` 一组，步骤 6 之后会变成两组，形如（数值取自**上一版机型** c6a.xlarge 与 c7g.xlarge 实测，换成 c7i/c9g 后需重测）：

```
==> 5) 粗略 CPU 对比：2 个分组 × 2000000 次 SHA-256（仅供参考，非正式基准测试）

   单核（threads=1）—— 反映单线程标量性能
   GROUP       INSTANCE-TYPE  OS-ARCH    THREADS     耗时(ms)          ops/s       相对
   amd64       c6a.xlarge     amd64            1     143.25     13,961,264     100%
   arm64       c7g.xlarge     aarch64          1     167.46     11,943,113      86%

   多核（threads = 容器可见 vCPU）—— 反映整机吞吐
   GROUP       INSTANCE-TYPE  OS-ARCH    THREADS     耗时(ms)          ops/s       相对
   arm64       c7g.xlarge     aarch64          4     162.18     49,327,232     100%
   amd64       c6a.xlarge     amd64            4     246.42     32,464,394      66%

   多核加速比（多核 ops/s ÷ 单核 ops/s，理想值 = 线程数）
   GROUP       INSTANCE-TYPE   THREADS          加速比         效率
   amd64       c6a.xlarge            4        2.33x        58%
   arm64       c7g.xlarge            4        4.13x       103%
```

**结论会随口径翻转，这是整个对比里最值得讲的一点**：单核 x86 领先 16%，
多核 Graviton 反超 52%。原因在加速比那张表里——c6a.xlarge 的 4 vCPU 是
2 个物理核开 SMT（加速比 2.33x），c7g.xlarge 的 4 vCPU 是 4 个真实物理核（4.13x）。
所以容器的 `limits.cpu` 必须给到全部 vCPU，否则 cgroup 配额会把多线程压回单核，
量出来的就只是单核结论。

第 6 步的原生依赖检查同样按多核跑（同样是上一版机型 c6a/c7g 的实测值）：

```
==> 6) 原生依赖检查（...），threads = 容器可见 vCPU
   lz4-java（jar 内置各架构 .so）
   GROUP       INSTANCE-TYPE  IMPLEMENTATION   原生so  THREADS    压缩率   压缩MiB/s  往返校验
   amd64       c6a.xlarge     LZ4Factory:JNI      yes        4     48.44        7568       ok
   arm64       c7g.xlarge     LZ4Factory:JNI      yes        4     46.19        9870       ok

   自研 libarchdemo_native.so（纯标量 C，无 SIMD，经 JNI 调用）
   GROUP       INSTANCE-TYPE   可用   so架构  架构匹配  THREADS  crc32MiB/s  fnv1aMiB/s
   amd64       c6a.xlarge       yes    amd64        ok        4        1619        2636
   arm64       c7g.xlarge       yes    arm64        ok        4        1383        3092
```

多线程下 lz4 压缩 Graviton 领先 30%（c7g 用 DDR5，lz4 在这个数据尺寸上偏内存带宽敏感），
自研库的 fnv1a 领先 17%。但 **crc32 在上一版机型上是 x86 领先 17%**——它是逐字节查表、
存在串行依赖链的负载，属于"延迟受限"类型，更吃单核主频而不是核数：c6a 的 EPYC 约 3.6 GHz、
c7g（Graviton3）约 2.6 GHz，核多也补不回来。

> **换成 c7i / c9g 之后这个反例大概率不再成立，必须重测。** 上面的解释依赖
> "x86 主频明显更高"这个前提，而 c7i 是 **3.2 GHz**、c9g（Graviton5）是 **3.3 GHz**——
> 主频优势已经反转，同时 c9g 仍是 4 个物理核对 c7i 的 2 核 + SMT。
> 所以 crc32 这一项很可能翻成 Graviton 领先。跑完步骤 5、6 拿到自己的数字再下结论，
> 不要沿用上面这段话向客户讲。

保留一个反例在 demo 里是有意的：不是所有负载都适合 Graviton，给客户一个可信的判断依据
比一张全绿的表更有说服力——前提是表里的数字来自你实际要用的机型。

新增节点组后不用改脚本：分组是从 Pod 的 `arch` 标签自动枚举出来的。
压测前每组会先跑一轮并丢弃结果——JIT 编译只发生在首次调用，否则"冷"的那一组会明显偏慢
（实测同一个 Pod 冷跑 250ms、热跑 191ms，不预热会得出错误结论）。

> `kubectl get pods -L arch` 里的 ARCH 列打印的是 **Pod 标签**，同时也是 Deployment selector
> 的一部分（selector 创建后不可变，所以各组必须取不同值，否则两个 Deployment 会互相抢 Pod）。
> 本流程里它的取值就是真实架构 `amd64` / `arm64`；但如果你再加第二个 arm64 节点组（比如 c6g），
> 新那组就必须换一个值（例如 `arm64-c6g`），此时标签就不再等于架构了。
> 真实架构以节点标签 `kubernetes.io/arch`、`node.kubernetes.io/instance-type` 和容器内 `uname -m` 为准，
> `05-verify.sh` 第 2、3 步会把这几项一起打出来。

手工验证：

```bash
# Pod 落在哪个节点、哪种架构
kubectl -n demo get pods -o wide -L arch

# 容器内真实架构：x86_64 / aarch64
kubectl -n demo exec deploy/java-arch-demo-amd64 -- uname -m
kubectl -n demo exec deploy/java-arch-demo-arm64 -- uname -m

# 本地访问服务
kubectl -n demo port-forward svc/java-arch-demo 8080:80
curl -s localhost:8080/          # 反复请求会在两种架构之间轮转
curl -s localhost:8080/api/info | jq '.architecture, .kubernetes'
```

`/api/info` 在两种节点上的关键差异：

```json
// c7i.xlarge
{ "osArch": "amd64",   "platform": "x86_64 (Intel/AMD)" }
// c9g.xlarge
{ "osArch": "aarch64", "platform": "AWS Graviton (aarch64)" }
```

可选：对外暴露（会创建 NLB，产生额外费用）

```bash
kubectl apply -f k8s/service-nlb.yaml
kubectl -n demo get svc java-arch-demo-nlb -w    # 等 EXTERNAL-IP
```

---

## 步骤 6（增量，演示重点）：新增 Graviton 节点组并把服务部署上去

这是给客户看的核心动作：**存量 x86 集群不动，只加一个节点组 + 改一行 nodeSelector**，
业务就跑在 Graviton 上了。

拆成两个脚本，方便在客户面前把因果分开演示：

```bash
./scripts/06-add-c9g-nodegroup.sh    # ① 只加节点组，业务不动
./scripts/05-verify.sh                # 可选：此时 Graviton 节点是空的，Pod 还全在 x86
./scripts/04b-deploy-java-arm64.sh    # ② 同一个镜像 tag 部署上去，Pod 落到 Graviton
```

**06 只加节点组**（不需要镜像，也不需要 ECR 权限）：

1. 打印改造前的节点与 Pod 分布，现场对照用
2. 查出 `c9g.xlarge` 的架构并用显式 `--ami-type` 调 `aws eks create-nodegroup`
   创建节点组（约 3~5 分钟；为什么不用 eksctl 见上面那一节）
3. 等节点带上 `eks.amazonaws.com/nodegroup=ng-graviton-c9g` 并 Ready
4. 再打印一次分布——新节点已就绪但上面没有任何业务 Pod，这一步的"空窗"是演示的关键画面

**04b 只部署业务**（与 04a 对称，只是 nodeSelector 不同）：

1. 先确认集群里有 arm64 节点，没有就提示先跑 06
2. 节点组名与实例类型从 arm64 节点的标签自动读取（填进 `/api/info` 的展示字段），
   也可用 `C9G_NODEGROUP` / `C9G_INSTANCE_TYPE` 覆盖
3. 用**同一个镜像 tag** 部署 `k8s/deployment-arm64.yaml`，并重新 apply Service
4. 验证：新 Pod 落点、容器内 `uname -m`、`/api/info` 采样、两个节点组的 Pod 分布

所有脚本都幂等，重复执行只会做就绪检查或滚动更新。
如果集群里存在多个 arm64 节点组，04b 会告警提示 `nodeSelector` 只按架构选、Pod 可能落到任意一个。

> 编号说明：脚本名按"动作"分组（04x = 部署 Java、06 = 加节点组、07x/08 = 多语言服务），
> 不是严格的执行顺序。增量演示的实际顺序是 **04a → 05 → 06 → 04b → 05**。

两个 Deployment 逐字对比只有一处不同：

```yaml
# k8s/deployment-amd64.yaml          # k8s/deployment-arm64.yaml
nodeSelector:                        nodeSelector:
  kubernetes.io/arch: amd64            kubernetes.io/arch: arm64
```

镜像地址、探针、资源限制、安全上下文全部相同。节点拉镜像时 containerd 会按自身架构
从 manifest list 里挑对应的那一份，所以**不需要为 Graviton 换镜像地址**。

`Service` 的 selector 只有 `app: java-arch-demo`，新 Pod 自动加入同一个服务后端，
访问同一个地址就能看到流量分摊到 x86 与 Graviton 两种实例上——这一点客户最关心。

手工执行等价命令：

```bash
IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/java-arch-demo:1.0.0

# 建 Graviton 节点组：显式指定 amiType，别让 eksctl 猜机型架构
ROLE=$(aws eks describe-nodegroup --cluster-name multi-arch-demo --nodegroup-name ng-x86-c7i \
         --region us-east-1 --query nodegroup.nodeRole --output text)
SUBNETS=$(aws eks describe-nodegroup --cluster-name multi-arch-demo --nodegroup-name ng-x86-c7i \
         --region us-east-1 --query 'nodegroup.subnets' --output text)
aws eks create-nodegroup --cluster-name multi-arch-demo --region us-east-1 \
  --nodegroup-name ng-graviton-c9g --node-role "$ROLE" --subnets $SUBNETS \
  --instance-types c9g.xlarge --ami-type AL2023_ARM_64_STANDARD \
  --disk-size 50 --scaling-config minSize=1,maxSize=2,desiredSize=1 \
  --labels demo.arch=arm64,demo.cpu=aws-graviton5,workload=java-demo
aws eks wait nodegroup-active --cluster-name multi-arch-demo \
  --nodegroup-name ng-graviton-c9g --region us-east-1

sed -e "s|IMAGE_PLACEHOLDER|$IMAGE|g" \
    -e "s|NODEGROUP_PLACEHOLDER|ng-graviton-c9g|g" \
    -e "s|INSTANCE_TYPE_PLACEHOLDER|c9g.xlarge|g" \
    k8s/deployment-arm64.yaml | kubectl apply -f -
kubectl -n demo rollout status deploy/java-arch-demo-arm64
```

可选参数：

```bash
# 换节点组名（记得同步改 infra/nodegroup-c9g.yaml 里的 name）
C9G_NODEGROUP=my-ng ./scripts/06-add-c9g-nodegroup.sh

# 改用 Graviton2 (c6g)：复制一份 infra/nodegroup-c9g.yaml 改名字与 instanceType，然后
NODEGROUP_FILE=infra/nodegroup-c6g.yaml C9G_NODEGROUP=ng-graviton-c6g \
  C9G_INSTANCE_TYPE=c6g.xlarge ./scripts/06-add-c9g-nodegroup.sh
```

选型参考（us-east-1 按需，已核对 Pricing API）：`c7i.xlarge` $0.1785/小时、
`c6g.xlarge` $0.136/小时、`c9g.xlarge` $0.17388/小时。c9g（Graviton5）比 c7i 便宜约 2.6%。

单核吞吐的 77%（对比 c6g 高 9%）那组数字来自**上一版机型 c6a/c7g** 的实测，不适用于
c7i/c9g：c9g 主频（3.3 GHz）和物理核数（4 核无 SMT）对 c7i（3.2 GHz、2 核 + SMT）都占优，
比值预期明显好于 77%。真实业务请用自己的负载压测后再定型号。

## 步骤 7~8（可选）：多语言服务（Go / Python / C++）

第二个 demo 服务，一个镜像里装了三种语言的实现，与 Java 服务**完全独立**
（不同 ECR 仓库、不同 Service、不同 app 标签，可以同时部署在 `demo` 命名空间里）。

它存在的意义是把"迁移 Graviton 时不同语言的工作量差异"变成可演示的事实：

| 语言 | 产物 | 换架构要做什么 |
| --- | --- | --- |
| Java | jar（架构无关字节码） | 一份产物通吃；但一旦引入 JNI 原生库就和下面几种一样了 |
| Python | .py 源码（解释执行） | 源码不用改，但要留意带原生扩展的依赖（wheel 是否有 aarch64 版） |
| Go | 原生二进制 | 必须为每种架构编译一次；**启用 CGO 后**还要连带处理原生依赖与 glibc 兼容 |
| C++ | 原生二进制 | 必须为每种架构编译一次，依赖库（本例 OpenSSL）也要对应架构；SIMD 代码还要各写一份 |

本服务里三处与架构强相关的实现：

**1. Go 经 CGO 调用自研 C 库。** `polyglot/cgo/` 是纯标量 C，构建时由 `cgo-builder` 阶段
编译成 `libgodemo_native.so`，Go 侧用 `CGO_ENABLED=1` 链接，rpath 写死 `/app/lib`，
运行镜像不需要 `LD_LIBRARY_PATH`。启用 CGO 的代价是产物不再纯静态、会动态链接 glibc，
所以构建镜像与运行镜像必须 glibc 兼容（本 demo 两者同为 Debian bookworm）。

**2. C++ 的 SIMD 按架构分支。** 同一个 `bench.cpp`，靠编译器预定义宏选择实现：

```cpp
#if defined(__x86_64__)
#include <immintrin.h>          // x86：SSE2 基线，-mavx2 时走 AVX2
#elif defined(__aarch64__)
#include <arm_neon.h>           // arm64：NEON 基线
#endif
...
#if defined(__AVX2__)           // _mm256_sad_epu8，一次 32 字节
#elif defined(DEMO_ARCH_X86) && defined(__SSE2__)   // _mm_sad_epu8，一次 16 字节
#elif defined(DEMO_ARCH_ARM64)  // vpadalq_u8 + vaddlvq_u16，一次 16 字节
#else                           // 标量兜底
#endif
```

`/api/simd` 会同时跑 SIMD 与标量两条路径并**断言结果逐位相等**（`resultsMatch`）。
移植 SIMD 代码时这个自校验比性能数字重要得多——本 demo 开发过程中它就抓出一个真实 bug：
NEON 归约误用了 `vaddvq_u16`（返回 `uint16_t`），8 个 lane 合计最大 522240 会被静默截断，
换成宽化版 `vaddlvq_u16`（返回 `uint32_t`）才正确。x86 路径完全正常，只有 arm64 错——
这正是跨架构 SIMD 最容易出的问题。

实测（上一版机型 c6a.xlarge 容器内，1 MiB 缓冲 × 200 轮）：

| 路径 | 吞吐 | 相对标量 |
| --- | --- | --- |
| x86 SSE2（基线） | 34.95 GiB/s | 11.7x |
| x86 AVX2（`-mavx2`） | 47.86 GiB/s | 16.7x |
| 标量 | 2.99 GiB/s | 1x |

**3. 测 SIMD 必须防编译器优化。** 第一版把结果算在循环外，量出 4003 GiB/s、加速 1413 倍这种
明显不可信的数字——编译器识别出循环不变量直接提到外面算了一次。现在每轮改写一个字节
并累加返回值，数字才落回内存带宽量级。

因此这个镜像采用**在对应架构的实例上原生构建**：

```
x86 实例 (c7i)      docker build → push  <repo>:1.0.0-amd64  ┐
                                                              ├─→ 合并 → <repo>:1.0.0
Graviton 实例 (c9g) docker build → push  <repo>:1.0.0-arm64  ┘
```

原生构建的好处：不需要 buildx、不需要 QEMU 模拟，编译速度就是本机速度，
编译期的架构相关优化也按真实硬件生效。

### 7a. 两台机器各自原生构建并推送

在 **x86 实例**上：

```bash
git clone <this-repo> && cd eks-multi-arch-demo
./scripts/07a-build-push-polyglot-native.sh     # 自动识别 uname -m → 推 :1.0.0-amd64
```

在 **Graviton 实例**上执行同一条命令，脚本会推 `:1.0.0-arm64`。
脚本会在推送后进镜像里自检，打印容器内的 `uname -m` 与三种语言的运行时版本。

### 7b. 合并成多架构 tag

```bash
./scripts/07b-create-polyglot-manifest.sh
# 等价：docker buildx imagetools create -t <repo>:1.0.0 <repo>:1.0.0-amd64 <repo>:1.0.0-arm64
```

### 8~9. 部署并对比

部署脚本按架构拆开，与 Java 侧的 04a / 04b 对称；跨架构的压测对比单独一个脚本
（多语言服务版的 `05-verify.sh`）：

```bash
./scripts/08a-deploy-polyglot-amd64.sh   # 部署到 x86
./scripts/08b-deploy-polyglot-arm64.sh   # 部署到 Graviton（需先有 Graviton 节点组）
./scripts/09-verify-polyglot.sh          # 三语言 × 两架构 压测对比
```

`08b` 会从 arm64 节点的标签自动读取节点组名与实例类型填进展示字段，
也可用 `C9G_NODEGROUP` / `C9G_INSTANCE_TYPE` 覆盖；只部署了一侧时 `09` 也能跑，表里只有一行。

`09` 默认用容器可见的全部 vCPU 压测，想看单核口径：

```bash
BENCH_THREADS=1 ./scripts/09-verify-polyglot.sh
```

用同一个负载（SHA-256 循环，四种语言的实现逻辑一致）按语言分组对比两种架构。接口：

| 路径 | 用途 |
| --- | --- |
| `GET /` | 纯文本：架构、容器可用核数、三种语言运行时、原生依赖与 SIMD 路径 |
| `GET /api/info` | 同样信息的 JSON |
| `GET /api/bench?lang=all` | 三种语言各跑一遍，`lang` 也可取 `go` / `python` / `cpp` |
| `GET /api/bench?lang=cpp&threads=1&iterations=2000000` | 指定语言、线程数、每线程迭代次数 |
| `GET /api/native?iterations=20000&sizeBytes=4096` | Go 经 CGO 调用自研 C 库（Adler-32 / FNV-1a） |
| `GET /api/simd?bytes=1048576&iterations=200` | C++ SIMD vs 标量，含结果一致性校验 |
| `GET /healthz`、`GET /readyz` | 探针 |

架构：Go 进程做 HTTP 前门，Python 与 C++ 以子进程方式调用（各自计时并输出 JSON，
所以进程启动开销不算进 `elapsedMillis`，而是单独报在 `spawnMillis` 里）。

实测参考（上一版机型 c6a.xlarge，每线程 100 万次，容器 `limits.cpu: 4`）：

| 语言 | 单线程 ops/s | 4 线程聚合 ops/s | 并发方式 |
| --- | --- | --- | --- |
| C++ | 12,710,958 | 28,456,824 | `std::thread` |
| Go | 11,934,966 | 43,022,256 | goroutine，GOMAXPROCS 按 cgroup 配额设置 |
| Python | 1,313,848 | 2,993,426 | 多进程（GIL 限制，线程无法并行纯计算） |

三个和这个服务有关的工程细节，演示时值得点出来：

- **Go 默认不认 cgroup 配额**。`runtime.NumCPU()` 读的是宿主机核数，容器里会超配 P 的数量。
  服务启动时会读 `/sys/fs/cgroup/cpu.max` 算出真实可用核数并设置 `GOMAXPROCS`，
  `/api/info` 里 `hostCPUs` 与 `containerCPUs` 两个值可以直接对比。
- **Python 的 GIL**。`threads>1` 时用 `multiprocessing` 而不是线程，否则纯计算跑不满多核——
  这在核数更多的 Graviton 实例上尤其明显。
- **OpenSSL 3.x 的调用方式对 C++ 性能影响巨大**。用 `EVP_MD_fetch` 取一次算法并复用是
  12.7M ops/s；如果每次循环把静态 `EVP_sha256()` 传给 `EVP_DigestInit_ex`（每次触发 provider 查找）
  只有 2.9M ops/s，legacy `SHA256()` 更慢（2.6M）。这类问题和架构无关，
  但容易在架构对比里被误读成"某个架构慢"。

清理：`kubectl -n demo delete -f k8s/polyglot/`（或直接删命名空间）。

## 清理

```bash
# 只删 k8s 资源（Java 与多语言两个服务都在 demo 命名空间里）
./scripts/90-cleanup.sh

# 只删 c9g 节点组，保留集群与其他节点组
DELETE_C9G=true ./scripts/90-cleanup.sh

# 连 ECR 仓库和整个集群一起删（集群删除约 10~15 分钟）
DELETE_ECR=true DELETE_CLUSTER=true ./scripts/90-cleanup.sh
```

## 已验证 / 待在集群中验证

本地已实际跑通（在 x86 机器上）：

- `mvn package` 产出 `app/target/java-arch-demo.jar`，接口 `/`、`/api/info`、`/api/bench`、
  actuator 探针均返回正常。
- `docker buildx build --platform linux/amd64,linux/arm64` 成功产出 OCI image index，
  其中包含 `linux/amd64` 与 `linux/arm64` 两个 manifest。
- amd64 镜像启动后报告 `osArch=amd64`；arm64 镜像在 QEMU 模拟下启动后报告 `osArch=aarch64`，
  两者用的是同一个 jar。
- 方式 B 的完整链路（用本地 registry 验证）：`03a` 原生构建并推送 `:1.0.0-amd64`，
  另一次推送 `:1.0.0-arm64`，`03b` 合并出的 `:1.0.0` 是包含 `linux/amd64` + `linux/arm64`
  的 manifest list；在移除 buildx 插件的情况下，`docker build` + `docker manifest create/push`
  的回退路径同样跑通。
- `eksctl create cluster -f infra/cluster.yaml --dry-run` 校验通过（EKS 1.36、1 个 x86 节点组、
  c7i.xlarge、AL2023）。
- **eksctl 无法创建 c9g 节点组，这是实际踩到的坑**（见下一节）。步骤 6 已改为
  `aws eks create-nodegroup` + 显式 `--ami-type`，`instance_arch()` 对
  c9g/c7i/c7g/c8g 四个机型的架构判定已用 EC2 API 实测通过。
- 机型事实经 AWS EC2 / Pricing API 核对：`c7i.xlarge` 4 vCPU / 2 物理核 + SMT / 3.2 GHz /
  $0.1785，`c9g.xlarge` 4 vCPU / 4 物理核无 SMT / 3.3 GHz / $0.17388（Graviton5）。
  `c9g.xlarge` 在 us-east-1 只有 a/b/c/d 四个可用区，**f 没有**。
- 全部 `scripts/*.sh` 通过 `bash -n`，`infra/` 与 `k8s/` 下所有 YAML 通过解析。

> **c7i / c9g 这一对尚未在真实集群上跑过。** README 里带数字的对比表都是上一版机型
> （c6a.xlarge / c7g.xlarge）的实测值，已在各处标注。换机型后请重跑步骤 5、6 取自己的数字，
> 尤其是 crc32 那个反例——c9g 主频已反超 c7i，结论可能翻转。

### 坑：eksctl 不认识新的 Graviton 机型家族，会给 arm64 节点组填 x86 的 amiType

用 `eksctl create nodegroup` 建 c9g 节点组会失败，CloudFormation 里的报错是：

```
[c9g.xlarge] is not a valid instance type for requested amiType AL2023_x86_64_STANDARD
```

原因：eksctl 判断一个机型是不是 Graviton，靠的是**硬编码的机型家族列表**
（a1、t4g、m6g、m7g、c6g、c7g、r6g、m8g、r8g、c8g 等，见
[eksctl ARM 支持文档](https://docs.aws.amazon.com/eks/latest/eksctl/arm-support.html)）。
`c9g` 不在列表里，于是被当成 x86，托管节点组的 `amiType` 就填成了
`AL2023_x86_64_STANDARD`，EKS 校验"机型架构 vs AMI 架构"时直接拒绝。

配置里写 `amiFamily: AmazonLinux2023` 挡不住这个问题——`amiFamily` 只决定操作系统家族，
真正的 `amiType` 是 eksctl 生成 CloudFormation 时按机型推断的。**`eksctl create nodegroup
--dry-run` 也查不出来**：dry-run 只把配置展开回显，不会暴露推断出的 `amiType`。
这一点值得记住，它意味着 dry-run 通过并不等于能创建成功。

本仓库的处理方式（`scripts/env.sh` + `scripts/06-add-c9g-nodegroup.sh`）：

1. `instance_arch()` 用 `aws ec2 describe-instance-types` 查**权威架构**，不猜机型名前缀
2. 架构映射成显式的 `--ami-type`（`AL2023_ARM_64_STANDARD` / `AL2023_x86_64_STANDARD`）
3. 用 `aws eks create-nodegroup` 创建，nodeRole 与子网继承自集群已有的节点组
   （不额外建 IAM 角色，也保证与现有节点同子网）
4. `clean_failed_nodegroup_stack()` 会清掉上次失败留下的 `ROLLBACK_COMPLETE` 栈再重建。
   eksctl 给它建的栈默认**开启终止保护**，直接 `delete-stack` 会报
   `cannot be deleted while TerminationProtection is enabled`，所以要先关保护再删。
   删之前会校验栈里的资源是否已全部 `DELETE_COMPLETE`，只要还有存活资源就报错退出、不硬删

这样任何新机型家族都不会再踩坑，代价是这一步不再由 eksctl 配置文件驱动。
如果你的机型 eksctl 本来就认识（c6g/c7g/c8g），可以走原来的 eksctl 路径：

```bash
USE_EKSCTL=true ./scripts/06-add-c9g-nodegroup.sh
```

节点组仍然是标准的 EKS 托管节点组，AMI 由 EKS 按 `amiType` 解析并自动更新——
和 eksctl 建出来的没有区别，不是自定义 AMI 方案（那会把 AMI 固定在某个 ID 上）。

#### 改成 CLI 创建之后，有三点和 eksctl/CloudFormation 路径不一样

`eksctl create nodegroup` 实际做的是"生成一个 CloudFormation 栈"，而
`aws eks create-nodegroup` 直接调 EKS API。**c9g 节点组不再有 CloudFormation 栈**
（`eksctl-<集群>-nodegroup-<名字>` 这个栈不会出现），带来三个差异：

| | eksctl / CFN 路径 | 现在的 CLI 路径 |
| --- | --- | --- |
| 声明式管理 | 有栈，可看 drift、按栈回滚 | 无栈，配置只存在于脚本参数里 |
| EC2 实例标签 | 配置里的 `tags` 会传播到 EC2 实例 | `--tags` 只打在**节点组资源**上，不到实例 |
| 磁盘类型 | 走自建启动模板，明确 gp3 / 50 GiB | 只能用 `--disk-size` 指定大小，类型用 EKS 默认 |

前两点对本 demo 没有影响：节点组照样是托管节点组，`eksctl get nodegroup` 和控制台都能看到，
`kubectl` 侧的标签（`demo.arch` / `demo.cpu` / `eks.amazonaws.com/nodegroup`）完全一致，
验证脚本读的是 Kubernetes 节点标签而不是 EC2 标签。

第三点如果你在意"两个节点组只有架构不同"的严谨性——x86 节点组由 eksctl 建，
磁盘是 gp3 50 GiB；Graviton 节点组用 EKS 默认磁盘类型。要完全对齐就得给 Graviton
节点组也建一个启动模板并用 `--launch-template` 传入。本仓库没有这么做，因为压测负载
（SHA-256 / lz4 / crc32）是 CPU 与内存密集型，根卷类型不影响结论。

还有一个连带影响已经在 `90-cleanup.sh` 里处理了：**EKS 要求先删完所有托管节点组才能删集群**
（[文档](https://docs.aws.amazon.com/eks/latest/userguide/delete-cluster.html)），
而 CLI 建的节点组不在 eksctl 的栈里。所以 `DELETE_CLUSTER=true` 时会先调
`delete_non_eksctl_nodegroups()` 把没有栈的节点组用 API 删掉并等待，再执行
`eksctl delete cluster`，避免删集群时卡在 `ResourceInUseException`。

尚未执行（需要真实资源，会计费，请按需运行上面的步骤）：创建 EKS 集群、推送镜像到 ECR、
在集群中部署与验证。

## 如果集群是按旧流程（一开始就带 Graviton 节点组）建的

旧版 `infra/cluster.yaml` 会在步骤 1 就建出 `ng-graviton-c6g`，`k8s/` 下也曾有一个
`deployment-c7g.yaml`（标签 `arch: arm64-c7g`）。另外**本仓库的机型已从 `c6a`/`c7g`
换成 `c7i`/`c9g`**，所以按旧版建的集群里节点组名是 `ng-x86-c6a` / `ng-graviton-c7g`，
与现在的配置对不上。要用新流程演示"从纯 x86 开始"，最干净的做法是重建集群
（换机型必然要替换节点组，等于把 EC2 重建一遍）；不想重建就手工收敛到新状态：

```bash
# 1) 清掉旧的 demo 负载（含旧的 java-arch-demo-c7g / java-arch-demo-arm64）
kubectl delete namespace demo --ignore-not-found

# 2) 删掉旧机型的节点组（名字按你集群里实际的来），只留/重建 x86，回到"改造前"
eksctl delete nodegroup --cluster multi-arch-demo --region us-east-1 --name ng-graviton-c6g --wait
eksctl delete nodegroup --cluster multi-arch-demo --region us-east-1 --name ng-graviton-c7g --wait
# 旧的 x86 节点组是 c6a，要换成 c7i 就得删掉重建（节点组的 instanceType 不可原地修改）：
eksctl delete nodegroup --cluster multi-arch-demo --region us-east-1 --name ng-x86-c6a --wait
eksctl create nodegroup -f infra/cluster.yaml --include ng-x86-c7i

# 3) 按新流程演示
./scripts/04a-deploy-java-amd64.sh                # 改造前：只有 x86
./scripts/06-add-c9g-nodegroup.sh    # 改造后①：加 Graviton 节点组
./scripts/04b-deploy-java-arm64.sh    # 改造后②：部署同一个镜像
```

注意 `java-arch-demo-arm64` 的 Deployment selector 在新旧版本里都是 `{app, arch: arm64}`，
可以原地 apply 更新；但如果集群里同时留着多个 arm64 节点组（例如 c7g 和 c9g），
`nodeSelector: kubernetes.io/arch=arm64` 会落到任意一个上，所以务必先删掉不需要的那个节点组。

镜像本身与机型无关：manifest list 里已有 `linux/amd64` + `linux/arm64` 两个 manifest，
换机型不需要重新构建或推送镜像（c7i 仍是 x86_64，c9g 仍是 aarch64）。

## Graviton 迁移备忘

- 纯 Java / JVM 代码无需改动即可运行在 aarch64；风险点在**含原生代码的依赖**
  （JNI、`.so`、netty-tcnative、snappy/lz4、rocksdb、部分商业 Agent 等），
  需要确认依赖版本提供 `linux-aarch64` 分类器或原生库。
  本 demo 用 `lz4-java` 演示了"上游已提供各架构 .so"的理想情况，
  以及 fat jar 下 `fastestInstance()` 会静默退回纯 Java 的坑（见步骤 4 的说明）。
- **自研原生库要纳入 CI 的架构矩阵**：本 demo 的 `libarchdemo_native.so`（JNI）与
  `libgodemo_native.so`（CGO）都必须按架构各编译一次，且编译镜像与运行镜像的 glibc 要兼容
  （Java 侧统一 AL2023/glibc 2.34，Go 侧统一 Debian bookworm/glibc 2.36）。
- **SIMD 代码要按架构分别实现并做结果自校验**：x86 的 SSE2/AVX2 与 arm64 的 NEON 语义不同，
  归约指令的返回宽度尤其容易踩（`vaddvq_u16` vs `vaddlvq_u16`）。
  没有"SIMD 结果 == 标量结果"的断言，这类 bug 在功能测试里很难暴露。
- 建议使用较新的 JVM（本 demo 用 Corretto 21），新版本在 aarch64 上的 JIT 与 GC 优化更完整。
- CI 中构建多架构镜像：本 demo 的“只 COPY jar”方式最省事；如果 Dockerfile 必须执行
  `RUN`（编译原生依赖等），则需要 QEMU（`docker run --privileged tonistiigi/binfmt --install arm64`）
  或使用原生 arm64 构建机（如 CodeBuild 的 ARM 计算类型），后者更快。
- 压测对比请用真实业务负载；`/api/bench` 只是一个数量级参考。
