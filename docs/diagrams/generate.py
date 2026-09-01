#!/usr/bin/env python3
"""
生成本 demo 的 AWS 风格架构图（官方图标，输出 PNG，可直接放进 PPT）。

依赖：
    python3 -m venv .venv && .venv/bin/pip install diagrams
    sudo apt-get install -y graphviz fonts-noto-cjk     # macOS: brew install graphviz
    # 没有 CJK 字体时图里的中文会渲染成方框

用法：
    .venv/bin/python docs/diagrams/generate.py

输出到 docs/diagrams/*.png，共七张。编号即建议的讲解顺序
（先摆现状，再讲原理，然后是怎么构建，最后给结果）：
    1-before-x86-only         改造前：存量集群只有 x86 节点组
    2-image-arch-resolution   原理：同一个 tag 如何按节点架构分发不同 manifest
    3-build-multiarch-image   构建：多架构镜像原生构建 + manifest list 合成（模拟 CI）
    4-after-add-graviton      改造后：增量添加 Graviton 节点组
    5-polyglot-build          多语言服务（Go/Python/C++）镜像的 4 阶段构建
    6-polyglot-runtime        多语言服务 Pod 内部的进程模型
    7-end-to-end-overview     端到端总览（两个服务、两个节点组、验证脚本）

注意：下面函数的定义顺序与编号不完全一致，实际生成顺序见文件末尾的 __main__。

图里的名称与仓库保持一致：节点组 ng-x86-c7i / ng-graviton-c9g，
镜像 java-arch-demo:1.3.0，命名空间 demo。改机型或改名后记得同步这个文件。
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, ECR, EKS
from diagrams.aws.general import Users
from diagrams.k8s.compute import Deployment, Pod
from diagrams.k8s.network import SVC
from diagrams.onprem.container import Docker
from diagrams.programming.language import C, Cpp, Go, Java, Python

OUT = Path(__file__).parent

# AWS 官方配色
ORANGE = "#FF9900"   # 镜像 / 构建流
BLUE = "#232F3E"     # x86 与通用控制流
GREEN = "#7AA116"    # arm64 / Graviton
GRAY = "#879196"     # 说明性连线

# 中文字体：没有它 graphviz 会把中文渲染成方框
FONT = "Noto Sans CJK SC"

GRAPH_ATTR = {
    "fontname": FONT,
    "fontsize": "20",
    "bgcolor": "white",
    "pad": "0.6",
    "splines": "spline",
    "nodesep": "0.6",
    "ranksep": "1.1",
}
NODE_ATTR = {"fontname": FONT, "fontsize": "12"}
EDGE_ATTR = {"fontname": FONT, "fontsize": "11"}
# Cluster 的标签字体要单独给，否则回退到默认字体
CLUSTER_ATTR = {"fontname": FONT, "fontsize": "14"}


def diagram(title: str, filename: str, **overrides):
    """统一的 Diagram 工厂，保证四张图风格一致。"""
    graph_attr = {**GRAPH_ATTR, **overrides.pop("graph_attr", {})}
    return Diagram(
        title,
        filename=str(OUT / filename),
        outformat="png",
        show=False,
        graph_attr=graph_attr,
        node_attr=NODE_ATTR,
        edge_attr=EDGE_ATTR,
        **overrides,
    )


def build_pipeline() -> None:
    """图 3：两台原生构建机 → 单架构 tag → manifest list → ECR。不用 QEMU。"""
    with diagram(
        "多架构镜像构建：在各自架构的实例上原生构建，再合成 manifest list（无 QEMU 模拟）",
        "3-build-multiarch-image",
        direction="LR",
    ):
        src = Docker("源码 + Dockerfile\napp/（Java）\npolyglot/（Go/Python/C++）")

        with Cluster("构建机：模拟 CI 的两个 runner", graph_attr=CLUSTER_ATTR):
            with Cluster("x86_64 runner", graph_attr=CLUSTER_ATTR):
                builder_x86 = EC2("EC2 c7i.xlarge\nIntel Sapphire Rapids")

            with Cluster("arm64 runner", graph_attr=CLUSTER_ATTR):
                builder_arm = EC2("EC2 c9g.xlarge\nAWS Graviton5")

        with Cluster("Amazon ECR 仓库 java-arch-demo", graph_attr=CLUSTER_ATTR):
            tag_amd = ECR(":1.3.0-amd64\nlinux/amd64")
            tag_arm = ECR(":1.3.0-arm64\nlinux/arm64")
            manifest = ECR(":1.3.0\nmanifest list\nOCI image index")

        src >> Edge(color=BLUE, label="git clone") >> builder_x86
        src >> Edge(color=BLUE) >> builder_arm

        builder_x86 >> Edge(
            color=ORANGE,
            label="03a-build-push-native.sh\ndocker build → docker push\n原生编译 JNI .so / CGO / SIMD",
        ) >> tag_amd
        builder_arm >> Edge(color=GREEN, label="同一份 Dockerfile\n同一条命令") >> tag_arm

        tag_amd >> Edge(
            color=ORANGE, style="dashed",
            label="03b-create-manifest-list.sh\ndocker manifest create / push",
        ) >> manifest
        tag_arm >> Edge(color=GREEN, style="dashed") >> manifest


def before_x86_only() -> None:
    """图 1：改造前，存量 x86 集群（步骤 1 → 4a）。

    这张图不画 ECR：镜像来源由图 2 与图 3 负责，这里只讲集群拓扑与流量走向，
    镜像信息写在 Deployment 的标签里。
    """
    with diagram(
        "改造前：存量 EKS 集群只有一个 x86 节点组，服务全部跑在 x86（步骤 1 → 4a）",
        "1-before-x86-only",
        direction="LR",
    ):
        users = Users("客户 / 演示者\nkubectl port-forward")

        with Cluster(
            "EKS 集群 multi-arch-demo（1.36）\nVPC：us-east-1a/b/c 私有子网 + NAT 网关",
            graph_attr=CLUSTER_ATTR,
        ):
            eks = EKS("EKS 控制平面")

            with Cluster("namespace: demo", graph_attr=CLUSTER_ATTR):
                svc = SVC("Service java-arch-demo\nClusterIP\nselector: app=java-arch-demo")

                with Cluster("节点组 ng-x86-c7i\n1 × c7i.xlarge（Intel / amd64）", graph_attr=CLUSTER_ATTR):
                    deploy_amd = Deployment(
                        "java-arch-demo-amd64\nimage: java-arch-demo:1.3.0\n"
                        "nodeSelector: kubernetes.io/arch=amd64"
                    )
                    pods_amd = [Pod("pod amd64"), Pod("pod amd64")]

        users >> Edge(color=BLUE) >> svc
        svc >> Edge(color=BLUE, label="100% 流量落在 x86") >> deploy_amd
        for p in pods_amd:
            deploy_amd >> Edge(color=BLUE) >> p
        eks - Edge(color=GRAY, style="dotted") - svc


def after_add_graviton() -> None:
    """图 4：改造后，增量添加 Graviton 节点组（步骤 6 → 4b）。"""
    with diagram(
        "改造后：增量加一个 Graviton 节点组，同一个镜像 tag 同时跑在两种架构上（步骤 6 → 4b）\n"
        "唯一改动：新增节点组 + 一份 Deployment（与 amd64 那份只差 nodeSelector 一行）",
        "4-after-add-graviton",
        direction="LR",
    ):
        users = Users("客户 / 演示者\n同一个访问地址")

        with Cluster(
            "EKS 集群 multi-arch-demo（1.36）\n集群、VPC、Service、镜像全部不动",
            graph_attr=CLUSTER_ATTR,
        ):
            eks = EKS("EKS 控制平面")

            with Cluster("namespace: demo", graph_attr=CLUSTER_ATTR):
                svc = SVC("Service java-arch-demo\nselector 只有 app=java-arch-demo\n因此同时选中两组 Pod")

                # 声明顺序会影响 graphviz 的上下排布：先声明 Graviton 组，
                # 渲染出来 x86 组反而在上方，与图 1 的位置保持一致（存量在上、新增在下）。
                with Cluster(
                    "节点组 ng-graviton-c9g（本次新增）\n1 × c9g.xlarge / Graviton5",
                    graph_attr=CLUSTER_ATTR,
                ):
                    deploy_arm = Deployment(
                        "java-arch-demo-arm64\nimage: java-arch-demo:1.3.0\narch=arm64"
                    )
                    pods_arm = [Pod("pod arm64"), Pod("pod arm64")]

                with Cluster("节点组 ng-x86-c7i（存量，不动）\n1 × c7i.xlarge", graph_attr=CLUSTER_ATTR):
                    deploy_amd = Deployment(
                        "java-arch-demo-amd64\nimage: java-arch-demo:1.3.0\narch=amd64"
                    )
                    pods_amd = [Pod("pod amd64"), Pod("pod amd64")]

        users >> Edge(color=BLUE) >> svc
        svc >> Edge(color=BLUE, label="约 50%") >> deploy_amd
        svc >> Edge(color=GREEN, label="约 50%\n同一个 Service") >> deploy_arm

        for p in pods_amd:
            deploy_amd >> Edge(color=BLUE) >> p
        for p in pods_arm:
            deploy_arm >> Edge(color=GREEN) >> p
        eks - Edge(color=GRAY, style="dotted") - svc


def image_arch_resolution() -> None:
    """图 2：同一个 tag 如何按节点架构解析出不同的 manifest。"""
    with diagram(
        "为什么同一个镜像 tag 能同时跑在两种架构上",
        "2-image-arch-resolution",
        direction="LR",
    ):
        with Cluster("Amazon ECR：java-arch-demo:1.3.0", graph_attr=CLUSTER_ATTR):
            index = ECR("manifest list\nOCI image index")
            m_amd = ECR("manifest\nlinux/amd64")
            m_arm = ECR("manifest\nlinux/arm64")

        with Cluster("EKS 节点组 ng-x86-c7i", graph_attr=CLUSTER_ATTR):
            node_x86 = EC2("c7i.xlarge\nkubelet + containerd")
            pod_x86 = Pod("Pod\nuname -m = x86_64")

        with Cluster("EKS 节点组 ng-graviton-c9g", graph_attr=CLUSTER_ATTR):
            node_arm = EC2("c9g.xlarge\nkubelet + containerd")
            pod_arm = Pod("Pod\nuname -m = aarch64")

        index >> Edge(color=ORANGE, label="按 architecture 字段索引") >> m_amd
        index >> Edge(color=GREEN) >> m_arm

        m_amd >> Edge(color=ORANGE, label="containerd 按节点架构自动挑选") >> node_x86
        m_arm >> Edge(color=GREEN, label="镜像地址一字不改") >> node_arm
        node_x86 >> Edge(color=BLUE) >> pod_x86
        node_arm >> Edge(color=BLUE) >> pod_arm


def polyglot_build() -> None:
    """图 5：多语言镜像的 4 阶段原生构建（polyglot/Dockerfile）。"""
    with diagram(
        "多语言服务的镜像构建：4 个阶段，Go 与 C++ 必须按架构各编一次（polyglot/Dockerfile）\n"
        "在 x86 与 Graviton 实例上各跑一遍 07a，再用 07b 合并成一个 tag",
        "5-polyglot-build",
        direction="LR",
    ):
        # 每个构建阶段压成一个节点：4 个阶段各画"源码 + 产物"两个节点的话，
        # 横向总宽度会让 graphviz 排成对角阶梯，留下大片空白。
        # 节点 label 必须短：graphviz 不把过宽的 label 算进 cluster 边界，
        # 写长了文字会溢出到框外被裁掉。基础镜像等细节放在 cluster 标题里。
        with Cluster(
            "构建阶段：Go 与 C++ 编译成原生机器码，必须按架构各编一次\n"
            "①② 用 golang:1.27-bookworm（同镜像保证 glibc 一致），③ 用 python:3.13-bookworm（自带 g++ 与 OpenSSL）",
            graph_attr=CLUSTER_ATTR,
        ):
            cgo_stage = C("① cgo-builder\ngodemo_native.c → .so\n纯标量，无 SIMD")
            go_stage = Go("② go-builder\nCGO_ENABLED=1 go build\nrpath /app/lib")
            cpp_stage = Cpp("③ cpp-builder\ng++ -std=c++17 -lcrypto\nx86→SSE2 / arm64→NEON")
            py_stage = Python("python/bench.py\n直接 COPY，不编译")

        with Cluster(
            "④ 运行镜像（python:3.13-slim，只有 COPY 没有 RUN）",
            graph_attr=CLUSTER_ATTR,
        ):
            image = ECR("polyglot-arch-demo\n:1.1.0-<arch>\n4 个产物 + USER 10001")

        # .so 既要参与 Go 的链接，又要单独进最终镜像
        cgo_stage >> Edge(color=ORANGE, label="头文件 + .so\n供 cgo 链接") >> go_stage
        cgo_stage >> Edge(color=ORANGE, style="dashed", label="/app/lib/") >> image
        go_stage >> Edge(color=ORANGE) >> image
        cpp_stage >> Edge(color=ORANGE) >> image
        py_stage >> Edge(color=GREEN) >> image


def polyglot_runtime() -> None:
    """图 6：多语言服务 Pod 内部的进程模型。"""
    with diagram(
        "多语言服务运行时：Pod 内只有一个常驻进程，Python / C++ 每次请求才 fork 子进程",
        "6-polyglot-runtime",
        direction="LR",
    ):
        users = Users("Service polyglot-arch-demo\nClusterIP 80 → 8080")

        with Cluster(
            "Pod（readOnlyRootFilesystem、USER 10001、limits.cpu = 4）",
            graph_attr=CLUSTER_ATTR,
        ):
            server = Go(
                "/app/polyglot-server（PID 1）\n唯一的网络前门\n"
                "GOMAXPROCS 按 cgroup cpu.max 设置"
            )

            with Cluster("同进程内：CGO 动态库调用", graph_attr=CLUSTER_ATTR):
                cgo_lib = C("/app/lib/libgodemo_native.so\nadler32 / fnv1a 标量循环\n经 rpath 定位，非子进程")

            with Cluster("按需 fork 的子进程（跑完即退出）", graph_attr=CLUSTER_ATTR):
                py_proc = Python("python3 /app/bench.py\nmultiprocessing 绕开 GIL")
                cpp_proc = Cpp("/app/bench-cpp\nstd::thread + OpenSSL EVP\n--simd 模式校验 SIMD vs 标量")

        users >> Edge(color=BLUE, label="HTTP") >> server
        server >> Edge(color=GREEN, label="/api/native\n同进程直接调用") >> cgo_lib
        server >> Edge(color=ORANGE, label="/api/bench?lang=python\nexec + JSON stdout") >> py_proc
        server >> Edge(
            color=ORANGE,
            label="/api/bench?lang=cpp\n/api/simd",
        ) >> cpp_proc


def end_to_end_overview() -> None:
    """图 7：从构建到验证的端到端总览（两个服务、两个节点组）。"""
    with diagram(
        "端到端总览：两台构建机 → 两个 ECR 仓库 → 两个节点组 → 两个 Service → 验证脚本",
        "7-end-to-end-overview",
        direction="LR",
        graph_attr={"ranksep": "1.4"},
    ):
        with Cluster("① 构建（每种架构各跑一次，原生编译）", graph_attr=CLUSTER_ATTR):
            build_x86 = EC2("EC2 c7i.xlarge\n02/03a（Java）\n07a（多语言）")
            build_arm = EC2("EC2 c9g.xlarge\n02/03a（Java）\n07a（多语言）")

        with Cluster("② Amazon ECR（03b / 07b 合并 manifest list）", graph_attr=CLUSTER_ATTR):
            ecr_java = ECR("java-arch-demo:1.3.0")
            ecr_poly = ECR("polyglot-arch-demo:1.1.0")

        with Cluster("③ EKS 集群 multi-arch-demo / namespace demo", graph_attr=CLUSTER_ATTR):
            with Cluster("ng-x86-c7i（01 建集群时创建）", graph_attr=CLUSTER_ATTR):
                java_amd = Java("java-arch-demo-amd64\n04a 部署")
                poly_amd = Go("polyglot-demo-amd64\n08a 部署")

            with Cluster("ng-graviton-c9g（06 增量添加）", graph_attr=CLUSTER_ATTR):
                java_arm = Java("java-arch-demo-arm64\n04b 部署")
                poly_arm = Go("polyglot-demo-arm64\n08b 部署")

        with Cluster("④ Service（各自一个，selector 不带 arch）", graph_attr=CLUSTER_ATTR):
            svc_java = SVC("java-arch-demo")
            svc_poly = SVC("polyglot-arch-demo")

        with Cluster("⑤ 验证", graph_attr=CLUSTER_ATTR):
            verify = Users("05-verify.sh\n09-verify-polyglot.sh\n架构分布 + 分组压测 + 原生依赖断言")

        # 每台构建机都要推**两个仓库**的对应架构 tag：
        # x86 机器出 :*-amd64，Graviton 机器出 :*-arm64，之后由 03b/07b 各自合并。
        build_x86 >> Edge(color=BLUE, label=":1.3.0-amd64") >> ecr_java
        build_x86 >> Edge(color=BLUE, label=":1.1.0-amd64") >> ecr_poly
        build_arm >> Edge(color=GREEN, label=":1.3.0-arm64") >> ecr_java
        build_arm >> Edge(color=GREEN, label=":1.1.0-arm64") >> ecr_poly

        ecr_java >> Edge(color=ORANGE) >> java_amd
        ecr_java >> Edge(color=ORANGE) >> java_arm
        ecr_poly >> Edge(color=ORANGE) >> poly_amd
        ecr_poly >> Edge(color=ORANGE) >> poly_arm

        java_amd >> Edge(color=BLUE) >> svc_java
        java_arm >> Edge(color=GREEN) >> svc_java
        poly_amd >> Edge(color=BLUE) >> svc_poly
        poly_arm >> Edge(color=GREEN) >> svc_poly

        svc_java >> Edge(color=GRAY, style="dashed") >> verify
        svc_poly >> Edge(color=GRAY, style="dashed") >> verify


if __name__ == "__main__":
    # 按编号（= 建议的讲解顺序）生成
    before_x86_only()        # 1 改造前
    image_arch_resolution()  # 2 原理
    build_pipeline()         # 3 构建
    after_add_graviton()     # 4 改造后
    polyglot_build()         # 5
    polyglot_runtime()       # 6
    end_to_end_overview()    # 7
    for png in sorted(OUT.glob("*.png")):
        print(f"生成 {png.relative_to(OUT.parent.parent)}  ({png.stat().st_size // 1024} KiB)")
