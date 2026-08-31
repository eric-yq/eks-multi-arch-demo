# EKS 多架构（x86 + Graviton）Java Demo

演示的是一条**迁移路径**，而不是一个一开始就多架构的集群：

> 客户现状：EKS 集群里全是 x86 节点，Java 服务跑在 x86 上。
> 演示动作：**新增一个 Graviton 节点组**，用**完全相同的镜像 tag** 把服务也部署上去，
> 存量集群、Service、镜像地址都不动。

| 阶段 | 集群状态 | 对应步骤 |
| --- | --- | --- |
| 改造前 | 1 个节点组 `ng-x86-c6a`：1 × `c6a.xlarge`（AMD64），服务只跑在 x86 | 步骤 1 → 4 |
| 改造后 | 增加 `ng-graviton-c7g`：1 × `c7g.xlarge`（Graviton3 / ARM64），同一个镜像同时跑在两种架构上 | 步骤 6 |

| 组成 | 说明 |
| --- | --- |
| EKS 集群 | `multi-arch-demo`，Kubernetes 1.36，us-east-1 |
| Java 应用 | Spring Boot 3.5.16 + Java 21，暴露架构信息与一个简易 CPU 压测接口 |
| 镜像 | 单个 tag 的 manifest list，同时包含 `linux/amd64` 与 `linux/arm64` |
| 部署 | 两个 Deployment 只有 `nodeSelector: kubernetes.io/arch` 一处不同，一个 Service 统一入口 |

## 目录结构

```
.
├── infra/
│   ├── cluster.yaml                # 步骤 1：集群 + 唯一的 x86 节点组
│   └── nodegroup-c7g.yaml          # 步骤 6：增量添加的 Graviton3 节点组（只含节点组）
├── app/                            # Java 应用
│   ├── pom.xml
│   ├── Dockerfile                  # 多架构镜像（只 COPY jar，无需 QEMU 交叉执行）
│   └── src/main/java/com/example/archdemo/
│       ├── ArchDemoApplication.java
│       ├── ArchInfoService.java    # 采集 os.arch / JVM / Pod / Node 信息
│       ├── ArchInfoController.java # GET /  与  GET /api/info
│       └── BenchmarkController.java# GET /api/bench  简易 CPU 对比
├── polyglot/                       # 第二个 demo 服务：Go + Python + C++ 单镜像
│   ├── Dockerfile                  # 原生多阶段构建（每种架构各构建一次，无需 QEMU）
│   ├── go/                         # HTTP 前门 + Go 压测 + cgroup CPU 识别
│   ├── python/bench.py             # Python 压测（多进程绕开 GIL）
│   └── cpp/bench.cpp               # C++ 压测（OpenSSL EVP，必须按架构编译）
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
    ├── 06-add-c7g-nodegroup.sh     # 增量：只加 Graviton 节点组（不动业务）
    ├── 07a-build-push-polyglot-native.sh  # 多语言镜像：在本机架构上原生构建并推送
    ├── 07b-create-polyglot-manifest.sh    # 多语言镜像：合并成多架构 tag
    ├── 08-deploy-polyglot.sh       # 多语言服务：部署到两种架构并对比
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
`c6a.xlarge` **$0.153/小时**，`c7g.xlarge` **$0.145/小时**（Graviton3 比同规格 x86 便宜约 5%），
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
  - name: ng-x86-c6a
    amiFamily: AmazonLinux2023
    instanceType: c6a.xlarge      # x86_64
    desiredCapacity: 1
```

Graviton 节点组不在这个文件里，而是单独放在 `infra/nodegroup-c7g.yaml`，由步骤 6 添加。
必须分成两个文件：`eksctl create cluster` 没有 `--include` 过滤节点组，写在一起的话建集群时就会
把 Graviton 节点一并建出来，"先只有 x86"的前提就没了。

验证：

```bash
kubectl get nodes -L kubernetes.io/arch,node.kubernetes.io/instance-type,eks.amazonaws.com/nodegroup
```

预期只看到 1 个节点，`ARCH=amd64`、`INSTANCE-TYPE=c6a.xlarge`。

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
        kubernetes.io/arch: amd64      # 落在 c6a.xlarge
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

步骤 4 之后跑只有 `amd64` 一组，步骤 6 之后会变成两组，形如（数值取自 c6a.xlarge 与 c7g.xlarge 实测）：

```
==> 5) 粗略 CPU 对比：2 个分组 × 2000000 次 SHA-256（仅供参考，非正式基准测试）
   GROUP       INSTANCE-TYPE  OS-ARCH       耗时(ms)          ops/s       相对    vCPU
   amd64       c6a.xlarge     amd64         148.36     13,481,043     100%       1
   arm64       c7g.xlarge     aarch64       191.55     10,441,234      77%       1
```

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
// c6a.xlarge
{ "osArch": "amd64",   "platform": "x86_64 (Intel/AMD)" }
// c7g.xlarge
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
./scripts/06-add-c7g-nodegroup.sh    # ① 只加节点组，业务不动
./scripts/05-verify.sh                # 可选：此时 Graviton 节点是空的，Pod 还全在 x86
./scripts/04b-deploy-java-arm64.sh    # ② 同一个镜像 tag 部署上去，Pod 落到 Graviton
```

**06 只加节点组**（不需要镜像，也不需要 ECR 权限）：

1. 打印改造前的节点与 Pod 分布，现场对照用
2. `eksctl create nodegroup -f infra/nodegroup-c7g.yaml` 创建节点组（约 3~5 分钟）
3. 等节点带上 `eks.amazonaws.com/nodegroup=ng-graviton-c7g` 并 Ready
4. 再打印一次分布——新节点已就绪但上面没有任何业务 Pod，这一步的"空窗"是演示的关键画面

**04b 只部署业务**（与 04a 对称，只是 nodeSelector 不同）：

1. 先确认集群里有 arm64 节点，没有就提示先跑 06
2. 节点组名与实例类型从 arm64 节点的标签自动读取（填进 `/api/info` 的展示字段），
   也可用 `C7G_NODEGROUP` / `C7G_INSTANCE_TYPE` 覆盖
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
eksctl create nodegroup -f infra/nodegroup-c7g.yaml
sed -e "s|IMAGE_PLACEHOLDER|$IMAGE|g" \
    -e "s|NODEGROUP_PLACEHOLDER|ng-graviton-c7g|g" \
    -e "s|INSTANCE_TYPE_PLACEHOLDER|c7g.xlarge|g" \
    k8s/deployment-arm64.yaml | kubectl apply -f -
kubectl -n demo rollout status deploy/java-arch-demo-arm64
```

可选参数：

```bash
# 换节点组名（记得同步改 infra/nodegroup-c7g.yaml 里的 name）
C7G_NODEGROUP=my-ng ./scripts/06-add-c7g-nodegroup.sh

# 改用 Graviton2 (c6g)：复制一份 infra/nodegroup-c7g.yaml 改名字与 instanceType，然后
NODEGROUP_FILE=infra/nodegroup-c6g.yaml C7G_NODEGROUP=ng-graviton-c6g \
  C7G_INSTANCE_TYPE=c6g.xlarge ./scripts/06-add-c7g-nodegroup.sh
```

选型参考（us-east-1 按需，已核对 Pricing API）：`c6a.xlarge` $0.153/小时、
`c6g.xlarge` $0.136/小时、`c7g.xlarge` $0.145/小时。c7g（Graviton3）比 c6a 便宜约 5%，
实测同一份 jar 的单核 SHA-256 吞吐约为 c6a 的 77%、比 c6g 高约 9%——
真实业务请用自己的负载压测后再定型号。

## 步骤 7~8（可选）：多语言服务（Go / Python / C++）

第二个 demo 服务，一个镜像里装了三种语言的实现，与 Java 服务**完全独立**
（不同 ECR 仓库、不同 Service、不同 app 标签，可以同时部署在 `demo` 命名空间里）。

它存在的意义是把"迁移 Graviton 时不同语言的工作量差异"变成可演示的事实：

| 语言 | 产物 | 换架构要做什么 |
| --- | --- | --- |
| Java | jar（架构无关字节码） | 什么都不用做，一份产物通吃 |
| Python | .py 源码（解释执行） | 源码不用改，但要留意带原生扩展的依赖（wheel 是否有 aarch64 版） |
| Go | 原生二进制 | 必须为每种架构编译一次（交叉编译很容易，`GOARCH` 即可） |
| C++ | 原生二进制 | 必须为每种架构编译一次，且依赖库（本例 OpenSSL）也要对应架构 |

因此这个镜像采用**在对应架构的实例上原生构建**：

```
x86 实例 (c6a)      docker build → push  <repo>:1.0.0-amd64  ┐
                                                              ├─→ 合并 → <repo>:1.0.0
Graviton 实例 (c7g) docker build → push  <repo>:1.0.0-arm64  ┘
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

### 8. 部署并对比

```bash
./scripts/08-deploy-polyglot.sh
```

部署到 x86 与 Graviton 两个节点组，然后用同一个负载（SHA-256 循环，四种语言的实现逻辑一致）
按语言分组对比两种架构。接口：

| 路径 | 用途 |
| --- | --- |
| `GET /` | 纯文本：架构、容器可用核数、三种语言的运行时版本、Pod/Node 信息 |
| `GET /api/info` | 同样信息的 JSON |
| `GET /api/bench?lang=all` | 三种语言各跑一遍，`lang` 也可取 `go` / `python` / `cpp` |
| `GET /api/bench?lang=cpp&threads=1&iterations=2000000` | 指定语言、线程数、每线程迭代次数 |
| `GET /healthz`、`GET /readyz` | 探针 |

架构：Go 进程做 HTTP 前门，Python 与 C++ 以子进程方式调用（各自计时并输出 JSON，
所以进程启动开销不算进 `elapsedMillis`，而是单独报在 `spawnMillis` 里）。

实测参考（同一台 c6a.xlarge，每线程 100 万次，容器 `limits.cpu: 4`）：

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

# 只删 c7g 节点组，保留集群与其他节点组
DELETE_C7G=true ./scripts/90-cleanup.sh

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
  c6a.xlarge、AL2023）。
- `eksctl create nodegroup -f infra/nodegroup-c7g.yaml --dry-run` 对着真实集群校验通过
  （AL2023 / c7g.xlarge / desiredCapacity 1，正确复用集群已有的私有子网）。
- `kubectl apply --dry-run=server` 对 `deployment-amd64.yaml` 与 `deployment-arm64.yaml`
  均返回 created（在真实 1.36 集群上验证了 schema 与准入检查）。

尚未执行（需要真实资源，会计费，请按需运行上面的步骤）：创建 EKS 集群、推送镜像到 ECR、
在集群中部署与验证。

## 如果集群是按旧流程（一开始就带 Graviton 节点组）建的

旧版 `infra/cluster.yaml` 会在步骤 1 就建出 `ng-graviton-c6g`，`k8s/` 下也曾有一个
`deployment-c7g.yaml`（标签 `arch: arm64-c7g`）。要用新流程演示"从纯 x86 开始"，
最干净的做法是重建集群；不想重建就手工收敛到新状态：

```bash
# 1) 清掉旧的 demo 负载（含旧的 java-arch-demo-c7g / java-arch-demo-arm64）
kubectl delete namespace demo --ignore-not-found

# 2) 删掉多余的 Graviton 节点组，只留 x86，回到"改造前"
eksctl delete nodegroup --cluster multi-arch-demo --region us-east-1 --name ng-graviton-c6g --wait
eksctl delete nodegroup --cluster multi-arch-demo --region us-east-1 --name ng-graviton-c7g --wait

# 3) 按新流程演示
./scripts/04a-deploy-java-amd64.sh                # 改造前：只有 x86
./scripts/06-add-c7g-nodegroup.sh    # 改造后①：加 Graviton 节点组
./scripts/04b-deploy-java-arm64.sh    # 改造后②：部署同一个镜像
```

注意 `java-arch-demo-arm64` 的 Deployment selector 在新旧版本里都是 `{app, arch: arm64}`，
可以原地 apply 更新；但如果集群里同时留着 c6g 和 c7g 两个 arm64 节点组，
`nodeSelector: kubernetes.io/arch=arm64` 会落到任意一个上，所以务必先删掉不需要的那个节点组。

## Graviton 迁移备忘

- 纯 Java / JVM 代码无需改动即可运行在 aarch64；风险点在**含原生代码的依赖**
  （JNI、`.so`、netty-tcnative、snappy/lz4、rocksdb、部分商业 Agent 等），
  需要确认依赖版本提供 `linux-aarch64` 分类器或原生库。
- 建议使用较新的 JVM（本 demo 用 Corretto 21），新版本在 aarch64 上的 JIT 与 GC 优化更完整。
- CI 中构建多架构镜像：本 demo 的“只 COPY jar”方式最省事；如果 Dockerfile 必须执行
  `RUN`（编译原生依赖等），则需要 QEMU（`docker run --privileged tonistiigi/binfmt --install arm64`）
  或使用原生 arm64 构建机（如 CodeBuild 的 ARM 计算类型），后者更快。
- 压测对比请用真实业务负载；`/api/bench` 只是一个数量级参考。
