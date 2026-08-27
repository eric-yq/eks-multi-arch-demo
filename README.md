# EKS 多架构（x86 + Graviton）Java Demo

在一个 EKS 集群里同时运行 x86 与 Graviton 节点，用**同一个 jar、同一个镜像 tag**把 Java 服务
部署到两种架构上，并能直接从接口看到每个 Pod 实际跑在哪种 CPU 上。

| 组成 | 说明 |
| --- | --- |
| EKS 集群 | `multi-arch-demo`，Kubernetes 1.36，us-east-1 |
| 节点组 1 | `ng-x86-c6a`：1 × `c6a.xlarge`（AMD64） |
| 节点组 2 | `ng-graviton-c6g`：1 × `c6g.xlarge`（Graviton2 / ARM64） |
| Java 应用 | Spring Boot 3.5.16 + Java 21，暴露架构信息与一个简易 CPU 压测接口 |
| 镜像 | 单个 tag 的 manifest list，同时包含 `linux/amd64` 与 `linux/arm64` |
| 部署 | 两个 Deployment 用 `nodeSelector: kubernetes.io/arch` 分别落到 x86 与 Graviton，一个 Service 统一入口 |

## 目录结构

```
.
├── infra/cluster.yaml              # eksctl 集群 + 两个托管节点组
├── app/                            # Java 应用
│   ├── pom.xml
│   ├── Dockerfile                  # 多架构镜像（只 COPY jar，无需 QEMU 交叉执行）
│   └── src/main/java/com/example/archdemo/
│       ├── ArchDemoApplication.java
│       ├── ArchInfoService.java    # 采集 os.arch / JVM / Pod / Node 信息
│       ├── ArchInfoController.java # GET /  与  GET /api/info
│       └── BenchmarkController.java# GET /api/bench  简易 CPU 对比
├── k8s/
│   ├── 00-namespace.yaml
│   ├── deployment-amd64.yaml       # nodeSelector kubernetes.io/arch=amd64
│   ├── deployment-arm64.yaml       # nodeSelector kubernetes.io/arch=arm64
│   ├── deployment-mixed.yaml       # 进阶：一个 Deployment 跨两种架构均匀分布
│   ├── service.yaml                # ClusterIP，同时选中两组 Pod
│   └── service-nlb.yaml            # 可选：对外暴露（会创建 NLB）
└── scripts/
    ├── env.sh                      # 共享变量与工具函数（AWS_REGION / CLUSTER_NAME / IMAGE_TAG ...）
    ├── 01-create-cluster.sh
    ├── 02-build-jar.sh
    ├── 03-build-push-image.sh      # 方式 A：一台机器交叉构建两种架构
    ├── 03a-build-push-native.sh    # 方式 B：在当前实例上原生构建单架构并推送
    ├── 03b-create-manifest-list.sh # 方式 B：把两个单架构 tag 合并成多架构 tag
    ├── 04-deploy.sh
    ├── 05-verify.sh
    └── 90-cleanup.sh
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
`c6a.xlarge` **$0.153/小时**，`c6g.xlarge` **$0.136/小时**（Graviton2 比同规格 x86 便宜约 11%），
另有 NAT 网关、EBS 与数据传输费用。**用完请执行清理步骤。**

所有脚本的参数都可用环境变量覆盖，例如：

```bash
export AWS_REGION=ap-southeast-1     # 换区域时脚本会自动去掉硬编码的可用区
export CLUSTER_NAME=my-demo
export IMAGE_TAG=1.0.1
```

---

## 步骤 1：创建 EKS 集群与两个节点组

```bash
./scripts/01-create-cluster.sh
# 等价于：eksctl create cluster -f infra/cluster.yaml
```

耗时约 15~20 分钟。核心配置：

```yaml
managedNodeGroups:
  - name: ng-x86-c6a
    amiFamily: AmazonLinux2023
    instanceType: c6a.xlarge      # x86_64
    desiredCapacity: 1
  - name: ng-graviton-c6g
    amiFamily: AmazonLinux2023
    instanceType: c6g.xlarge      # ARM64 / Graviton2
    desiredCapacity: 1
```

同一个 `amiFamily` 即可，eksctl 会依据实例类型自动选择 x86_64 或 arm64 的 AL2023 AMI，
不需要手工指定 ARM 镜像。

验证：

```bash
kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup
```

预期看到两个节点，`ARCH` 列分别是 `amd64` 与 `arm64`。

## 步骤 2：构建 Java 应用的 jar

```bash
./scripts/02-build-jar.sh
# 产物：app/target/java-arch-demo.jar
```

脚本优先用本机 JDK 21+，找不到就自动回退到容器内构建（`maven:3.9-amazoncorretto-21`）。

应用接口：

| 路径 | 用途 |
| --- | --- |
| `GET /` | 纯文本汇总：CPU 架构、JVM、Pod、Node、节点组、实例类型 |
| `GET /api/info` | 同样的信息，JSON 格式，便于脚本统计架构分布 |
| `GET /api/bench?iterations=2000000` | SHA-256 循环，粗略对比 x86 与 Graviton 的 CPU 表现 |
| `GET /actuator/health/{liveness,readiness}` | 给 k8s 探针用 |

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

**为什么一个 jar 能同时服务两种架构**：jar 里是与架构无关的字节码，差异只在基础镜像自带的 JVM。
`Dockerfile` 因此只有 `FROM` / `COPY` / `ENV`，没有需要在目标架构上执行的 `RUN`，
在 x86 机器上交叉构建 arm64 镜像**不需要 QEMU 模拟**，构建时间和单架构几乎一样：

```dockerfile
FROM public.ecr.aws/amazoncorretto/amazoncorretto:21-al2023-headless
COPY target/java-arch-demo.jar /app/app.jar
USER 10001                     # 数字 UID，避免 RUN useradd 引入跨架构执行
ENTRYPOINT ["sh", "-c", "exec java $JAVA_OPTS -jar /app/app.jar"]
```

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

在 **x86 实例**（例如 c6a.xlarge）上：

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
合并完再打印 manifest list 校验结果。之后的 `04-deploy.sh` / `05-verify.sh` 完全不变。

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

## 步骤 4：把服务部署到 x86 与 Graviton 节点

```bash
./scripts/04-deploy.sh
```

脚本把 manifest 里的 `IMAGE_PLACEHOLDER` 替换成真实镜像地址后 apply。两个 Deployment
**镜像 tag 完全相同**，唯一区别是 `nodeSelector`：

```yaml
# k8s/deployment-amd64.yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: amd64      # 落在 c6a.xlarge
---
# k8s/deployment-arm64.yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/arch: arm64      # 落在 c6g.xlarge（Graviton）
```

`kubernetes.io/arch` 是 kubelet 自动打的标签，不需要自定义。节点拉取镜像时，
containerd 会根据自身架构从 manifest list 里挑选对应的那一份，所以两边用同一个 tag 即可。

手工执行等价命令：

```bash
IMAGE=<account>.dkr.ecr.<region>.amazonaws.com/java-arch-demo:1.0.0
kubectl apply -f k8s/00-namespace.yaml
for f in deployment-amd64.yaml deployment-arm64.yaml service.yaml; do
  sed "s|IMAGE_PLACEHOLDER|$IMAGE|g" k8s/$f | kubectl apply -f -
done
kubectl -n demo rollout status deploy/java-arch-demo-amd64
kubectl -n demo rollout status deploy/java-arch-demo-arm64
```

其他常见的架构调度方式（按需选用）：

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

脚本依次输出：节点架构表 → Pod 落点 → 每个 Pod 容器内 `uname -m` → 通过 Service 访问 10 次的
架构分布统计 → 两种架构各跑一次 `/api/bench` 的耗时对比。

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
// c6a.xlarge
{ "osArch": "amd64",   "platform": "x86_64 (Intel/AMD)" }
// c6g.xlarge
{ "osArch": "aarch64", "platform": "AWS Graviton (aarch64)" }
```

可选：对外暴露（会创建 NLB，产生额外费用）

```bash
kubectl apply -f k8s/service-nlb.yaml
kubectl -n demo get svc java-arch-demo-nlb -w    # 等 EXTERNAL-IP
```

---

## 清理

```bash
# 只删 k8s 资源
./scripts/90-cleanup.sh

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
- `eksctl create cluster -f infra/cluster.yaml --dry-run` 校验通过（EKS 1.36、两个节点组、
  c6a.xlarge/c6g.xlarge、AL2023）。

尚未执行（需要真实资源，会计费，请按需运行上面的步骤）：创建 EKS 集群、推送镜像到 ECR、
在集群中部署与验证。

## Graviton 迁移备忘

- 纯 Java / JVM 代码无需改动即可运行在 aarch64；风险点在**含原生代码的依赖**
  （JNI、`.so`、netty-tcnative、snappy/lz4、rocksdb、部分商业 Agent 等），
  需要确认依赖版本提供 `linux-aarch64` 分类器或原生库。
- 建议使用较新的 JVM（本 demo 用 Corretto 21），新版本在 aarch64 上的 JIT 与 GC 优化更完整。
- CI 中构建多架构镜像：本 demo 的“只 COPY jar”方式最省事；如果 Dockerfile 必须执行
  `RUN`（编译原生依赖等），则需要 QEMU（`docker run --privileged tonistiigi/binfmt --install arm64`）
  或使用原生 arm64 构建机（如 CodeBuild 的 ARM 计算类型），后者更快。
- 压测对比请用真实业务负载；`/api/bench` 只是一个数量级参考。
