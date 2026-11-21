# NUMA 绑定与重排优化记录

> 参考环境：2× Xeon Silver 4210（10C/20T ×2，Cascade Lake，AVX-512）、93GB RAM、双 NUMA、2× RTX 4080 16G。不同 CPU 拓扑需要重新核对，不要直接照抄核编号。

## 1. 硬件拓扑

- 2 个 NUMA 节点
- node0：62GB 内存，GPU0（示例 PCI 地址 `3b:00`）
- node1：32GB 内存，GPU1（示例 PCI 地址 `d8:00`）
- 整机 93GB，常态 available 约 75GB（page cache 占比较大）

检查命令：

```bash
numactl --hardware
nvidia-smi topo -m
lspci -vv -s <GPU_BDF> | grep -A2 Lnk
```

## 2. 变更清单

| 对象 | 变更 | 目的 |
|---|---|---|
| vLLM Deployment | `numactl --interleave=all` | 主机内存双节点均分，避免 worker 内存全落在 node0 |
| vLLM Deployment | `--max-num-seqs: 4 → 2` | 池容量约束下，保证排队而不是互相抢占 |
| embedding Deployment | `taskset -c 10-19,30-39` | CPU 钉 NUMA1，内存随 CPU 本地化 |
| embedding Deployment | `limits.cpu: 8 → 16` | 重排计算提速约 2× |
| embedding Deployment | `imagePullPolicy: IfNotPresent` | 规避镜像仓库抖动导致的 ImagePullBackOff |

> `taskset` 的核编号必须按 `numactl --hardware` 的实际输出修改。不同主板/CPU 的编号可能完全不同。

## 3. 容量账

以 35B 级 MoE、FP8 KV 为例：

```text
每 token KV = 40 层 × 2 KV 头 × head_dim 256 × 2 字节
            = 40,960 B/token
```

参考池容量：

- 2.51GiB/卡 × 2 卡 ≈ 131,600 tokens（较早配置）
- 最终配置的 KV 池约 438K tokens（0.93 util，FP8 KV）
- 舒适并发 = 2 × 约 55K 上下文
- 换回 FP16 KV，池容量约减半

vLLM 的撞墙语义：

```text
无熔断 → 排队 → 抢占（preempt/retract）→ 客户端超时
```

监控关键词：`preempt`、`retract`。

## 4. 重排超时的根因

RAG 检索链路：

```text
RRF 融合两路各 top-20
  → 最多 40 个唯一候选 chunk
  → 全部送 bge-reranker-v2-m3
  → 每条证据窗口约 352 tokens
```

远程重排路径有硬编码 60s 预算；候选规模 × CPU 重排速度超过 60s 就会降级。

## 5. 效果

| 指标 | 优化前 | 优化后 |
|---|---:|---:|
| 40 候选重排耗时 | 超 60s，降级 | 39.5s（预算内） |
| embedding 吞吐 | 23.9 items/s | 29.4 items/s（+23%） |
| 重排降级 | 频繁 | 连续验证 0 次 |

重排余量约 33%（39.5s / 60s）。如果要继续提升：

- 换更小的 reranker（如 bge-reranker-base，预计快 3–4×，精度待评）
- embedding / rerank 拆成两个 Pod，分占 NUMA
- 把远程重排超时做成可配置

## 6. 可观测性

参考实现使用：

- Prometheus + Grafana + Alertmanager
- 15s 采样 vLLM KV / 队列、embedding 队列、NUMA 内存
- 30s 捕获压缩、重排降级、抢占事件
- KV ≥ 85% 记录告警
- 告警经 webhook 进入事件库，再转发到聊天工具

注意：

- infinity 的 `/metrics` 不含队列指标，需要采集器从模型服务侧补
- Prometheus 配置文件的属主必须是运行用户，否则会 permission denied
- Grafana 首次启动的账号密码不要写进仓库；用环境变量或密钥管理

## 7. 双实例拆分方案（未实施）

触发条件：2 并发下重排仍频繁超时（当前余量 33%，暂不需要）。

形态：**StatefulSet ×2**，而不是 Deployment 双副本。原因：

- Pod 固定身份，语义清晰
- 避免用环境变量 hack 区分实例
- 同端口双副本会因 hostPort 冲突 Pending，需要改双端口/headless Service

切分方式：**按功能切，不按流量切**。

- embedding-0：只载 bge-m3，绑 node0，端口 7997
- embedding-1：只载 bge-reranker，绑 node1，端口 7998
- RAG 前端：`embeddingBaseUrl` → 7997，`rerankBaseUrl` → 7998

收益：rerank 独占 16 核、每 Pod 内存减半、启动更快、消除 embed/rerank 批处理互挤。

## 8. 其他踩坑

- **hostPort 滚动更新**：新 Pod 因端口占用 Pending，需 `strategy: Recreate` 或手动删旧 Pod。
- **JSON merge patch**：会整体替换 `containers` 数组，漏字段就报错；改容器字段用 strategic merge patch。
- **hostNetwork DNS**：必须显式 `dnsPolicy: ClusterFirstWithHostNet`，否则集群内域名不解析。
- **kubelet CPU manager**：如需独占物理核，改 static policy + Guaranteed QoS，需滚动 kubelet，低峰实施。
- **镜像仓库抖动**：固定 `imagePullPolicy: IfNotPresent` 或使用本地镜像，生产环境建议固定 digest。
