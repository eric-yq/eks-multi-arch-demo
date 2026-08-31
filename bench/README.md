# 容器启动耗时基准工具

在**单台实例**上批量启动容器，测量每个容器的启动耗时，输出 min / p50 / avg / p90 / p95 / p99 / max / stddev 统计报告。

只依赖 `docker` CLI 与 Python 3 标准库（无第三方包），与仓库其他脚本互不影响，可以单独拷走使用。

配合本仓库的多架构镜像，在 x86（c6a）和 Graviton（c6g / c7g）实例上各跑一遍同一条命令，就能对比同一个镜像在不同架构上的启动表现。

## 测量的三个阶段

"容器启动时间"有歧义，所以拆开测，报告里三行都给：

| 阶段 | 含义 | 典型量级 |
| --- | --- | --- |
| `docker run 返回` | `docker run -d` 命令本身的耗时，即 daemon 创建 + 启动容器的调用延迟 | 百毫秒级 |
| `应用就绪 累计` | 从发起 `docker run` 到就绪探测通过的**端到端**耗时（含上一行）。JVM 冷启动主要体现在这里 | 取决于应用 |
| ↳ `其中等待就绪` | 上一行减去 CLI 耗时，即纯应用初始化时间 | 取决于应用 |
| `docker 自报启动` | 容器 `State.StartedAt - Created`，纯 daemon/runtime 开销，不含应用初始化，用于交叉验证 | 几十毫秒 |

只有 `--ready` 不是 `none` 时才会有"应用就绪"相关的行。

## 前置条件

- `docker` 可用且当前用户能连上 daemon（否则报错退出码 2）
- Python 3.9+
- 镜像已在本地，或加 `--pull` 让脚本先拉

> 用 `sudo` 跑时注意：`sudo` 会丢掉当前用户的 AWS 凭证与环境变量，如果镜像在 ECR，
> 请先在普通用户下 `aws ecr get-login-password ... | docker login ...` 并 `docker pull`，
> 或者把当前用户加入 `docker` 组（`sudo usermod -aG docker $USER` 后重新登录）避免 sudo。

## 快速开始

```bash
# 1) 最小验证：50 个 alpine，只测 docker run 返回（不做就绪探测）
./bench/container-startup-bench.py \
  --image public.ecr.aws/docker/library/alpine:3.22 \
  --count 50 -- sleep 60

# 2) 本仓库的 Java 服务：50 个容器，等 actuator readiness 返回 2xx
./bench/container-startup-bench.py \
  --image <account>.dkr.ecr.<region>.amazonaws.com/java-arch-demo:1.0.0 \
  --count 50 --memory 512m --cpus 1 --ready http \
  --json /tmp/startup.json --csv /tmp/startup.csv

# 3) 并发密度场景：10 个一起启动，容器全部保留到结束
./bench/container-startup-bench.py --image ... \
  --count 50 --concurrency 10 --cleanup end --memory 512m --ready http
```

容器的启动命令写在 `--` 之后（例 1 的 `sleep 60`）。镜像自带 `CMD/ENTRYPOINT` 时不用写。

## 参数

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `--image` | 必填 | 镜像地址 |
| `--count` | `50` | 计入统计的容器数量 |
| `--concurrency` | `1` | 并发启动数。`1` 为串行，得到最干净的单容器耗时；`>1` 用于测争抢/密度 |
| `--warmup` | `1` | 预热容器数，不计入统计，抵消首次拉起镜像层的开销 |
| `--ready` | `none` | 就绪探测方式：`none` / `tcp` / `http` / `log` |
| `--ready-port` | `8080` | `tcp` / `http` 探测端口 |
| `--ready-path` | `/actuator/health/readiness` | `http` 探测路径，接受 2xx |
| `--ready-log-pattern` | `Started .* in .* seconds` | `log` 探测的正则，默认匹配 Spring Boot 启动日志 |
| `--ready-timeout` | `120` | 单个容器就绪超时（秒） |
| `--ip-timeout` | `20` | 等待容器分配 IP 的超时（秒），网络模式不对时快速失败 |
| `--max-consecutive-failures` | `3` | 连续失败达到该数就中止整轮，`0` 表示跑完全部样本 |
| `--poll-interval` | `0.02` | 探测轮询间隔（秒） |
| `--memory` | 无 | 每容器内存上限，如 `512m`。**JVM 镜像务必设置**，见下方注意事项 |
| `--cpus` | 无 | 每容器 CPU 上限，如 `1` |
| `--platform` | 无 | 指定平台，如 `linux/arm64`（非本机架构需要 QEMU，不代表原生性能） |
| `--env` | 无 | 传给容器的环境变量 `K=V`，可重复 |
| `--docker-arg` | 无 | 附加到 `docker run` 的原始参数，可重复，如 `--docker-arg '--network mynet'` |
| `--cleanup` | `each` | `each` 测完一个删一个；`end` 全部保留到结束再删（测密度用） |
| `--name-prefix` | `cstart-bench` | 容器名前缀 |
| `--pull` | 关 | 开始前先 `docker pull` |
| `--json` / `--csv` | 无 | 写出完整结果 / 逐容器原始数据 |
| `--quiet` | 关 | 不打印逐容器进度 |

## 报告样例

```
====================================================================================================
                                          容器启动耗时报告
====================================================================================================
主机        : ip-172-31-86-86  (x86_64, 4 vCPU, 7.6 GiB, Linux 7.0.0-1011-aws)
实例        : c6a.xlarge  us-east-1c
Docker      : 29.1.3
镜像        : 022633198646.dkr.ecr.us-east-1.amazonaws.com/java-arch-demo:1.0.0
              linux/amd64  sha256:c2ce0e1e8d449fa5e2b...  解压后 401.8 MiB
参数        : 数量 6  并发 1  内存上限 512m  CPU 上限 1  就绪探测 http /actuator/health/readiness:8080
              预热 1（不计入统计）  容器回收 each  轮询间隔 20ms
时间        : 2026-08-31 02:32:47 UTC  总耗时 53.4s  吞吐 0.11 容器/秒
样本        : 成功 6 / 失败 0（计划 6，另有 1 个预热）
----------------------------------------------------------------------------------------------------
阶段                          n       min       p50       avg       p90       p95       p99       max    stddev
docker run 返回 (ms)          6     170.5     176.8     177.0     183.2     185.4     187.2     187.7       6.2
应用就绪 累计 (ms)            6    7363.7    7423.3    7452.5    7547.1    7554.2    7559.8    7561.2      77.2
  其中等待就绪 (ms)           6    7185.0    7249.6    7275.5    7364.5    7374.1    7381.7    7383.6      74.1
docker 自报启动 (ms)          6      51.3      52.8      52.7      53.8      53.9      54.0      54.0       1.1
----------------------------------------------------------------------------------------------------
百分位算法：线性插值（同 numpy.percentile 默认）。
```

报告头部会自动带上主机架构/vCPU/内存、IMDS 读到的实例类型与可用区、Docker 版本、镜像的 `os/arch` 与 digest——
跨实例对比时这些信息就是"这组数据是在什么环境上跑出来的"的凭据。

## 输出文件

- `--json`：`host` / `image` / `params` / `stats`（各阶段统计）/ `samples`（逐容器原始值），适合入库或做多次运行的横向对比
- `--csv`：逐容器一行，字段 `index,name,warmup,ok,cli_start_ms,ready_ms,wait_ms,daemon_ms,container_id,error`，适合丢进表格画分布图

## 对比 x86 与 Graviton

在两台实例上跑**同一条命令**（镜像用同一个多架构 tag，各节点会自动拉到对应架构那一份）：

```bash
# 在 c6a.xlarge 上
./bench/container-startup-bench.py --image <ecr>/java-arch-demo:1.0.0 \
  --count 50 --memory 512m --cpus 1 --ready http --json /tmp/c6a.json

# 在 c7g.xlarge 上（命令完全一样）
./bench/container-startup-bench.py --image <ecr>/java-arch-demo:1.0.0 \
  --count 50 --memory 512m --cpus 1 --ready http --json /tmp/c7g.json
```

不要用 `--platform` 在一台机器上"模拟"另一种架构做性能对比：那会走 QEMU 翻译，数字没有参考价值。

## 注意事项

**JVM 镜像必须给 `--memory`。** 不设上限时每个 JVM 都按宿主机内存计算堆上限
（本仓库镜像用的是 `-XX:MaxRAMPercentage=75`），容器一多必然 OOM。`512m` 是本仓库 Java 服务实测可用的值。

**`--cleanup each`（默认）测的是单容器启动，`--cleanup end` 测的是密度。** 默认每测完一个就删掉，
否则 50 个 JVM 会把小实例的内存吃满。想看"同时跑 N 个"的表现再用 `end`。

**并发会显著影响结果，这是特性不是噪声。** 实测同一镜像在 4 vCPU 实例上：串行时就绪 p50 约 7.4s，
`--concurrency 3` 时升到约 10.0s，`docker run` 返回也从 177ms 升到 307ms。报告参数行会记录当次并发数。

**就绪探测走容器在 bridge 网络上的 IP**，不发布端口，所以起几十个容器不会有端口冲突。
用了 `host` / `none` 网络或自定义网络时，改用 `--ready log`，或用 `--docker-arg` 指定网络后配合 `tcp`/`http`。

**Docker 29 移除了 `.NetworkSettings.IPAddress` 顶层字段**，脚本解析 `{{json .NetworkSettings}}`
并同时兼容旧版顶层字段与新版 `Networks[*].IPAddress`，新旧版本都能取到 IP。

**连续失败会中止。** 默认连续 3 个容器失败即中止整轮并打印排查建议，剩余样本标记为"未执行"，
避免一个配置错误浪费 50 次超时等待。加 `--max-consecutive-failures 0` 可强制跑完。

## 清理与安全

脚本只会删除自己创建的容器——必须同时满足带 `label=cstart-bench=1` 且容器名匹配 `--name-prefix`，
不会碰机器上其他容器。启动前会先清一遍上次残留，`Ctrl+C` / `SIGTERM` 也会先清理再退出。

手工清理：

```bash
docker ps -aq --filter label=cstart-bench=1 --filter name=^cstart-bench- | xargs -r docker rm -f
```

## 退出码

| 码 | 含义 |
| --- | --- |
| `0` | 全部样本成功 |
| `1` | 有失败样本（报告里会列出原因） |
| `2` | 环境问题：连不上 docker daemon、或镜像不存在且未加 `--pull` |
| `130` | 被 `Ctrl+C` 中断（容器已清理） |

## 实测参考数据

环境：`c6a.xlarge`（4 vCPU / 7.6 GiB，us-east-1c），Docker 29.1.3，串行、`--warmup 1`。仅供量级参考。

| 场景 | min | p50 | p95 | max |
| --- | --- | --- | --- | --- |
| alpine × 50，`docker run` 返回 | 164.6 ms | 176.5 ms | 188.1 ms | 193.1 ms |
| alpine × 50，docker 自报启动 | 49.9 ms | 51.8 ms | 55.6 ms | 57.7 ms |
| Java 服务 × 6，应用就绪累计（`--cpus 1 --memory 512m`） | 7363.7 ms | 7423.3 ms | 7554.2 ms | 7561.2 ms |
| Java 服务 × 6，并发 3，应用就绪累计 | 9773.5 ms | 10029.8 ms | 10194.8 ms | 10214.5 ms |

alpine × 50 全程 15.9s（3.15 容器/秒）。Java 服务的就绪耗时里，`docker run` 只占 177ms，
其余约 7.25s 全是 JVM + Spring Boot 自身初始化——这也是为什么必须把两个阶段分开测。
