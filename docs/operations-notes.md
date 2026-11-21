# 运维与调优笔记

> 记录单节点双卡推理平台在容量、显存、KV 缓存、NUMA 和可观测性上的关键取舍。所有数值来自参考环境，换硬件或模型后需要重新核算。

## 1. 容量核算

参考环境：

- 2× RTX 4080 16G
- 2× Xeon Silver 4210，93GB RAM，双 NUMA
- 35B 级 MoE 模型，AWQ-Int4 权重，FP8 KV
- vLLM 0.31，TP2，128K 上下文

关键结论：

- 权重约 11.3GB/卡，FP8 KV 约 10KB/token
- 参考配置的 KV 池约 438K tokens
- 可支撑 2–3 路 128K 会话，但并发数必须和池容量一起核算
- 不要只看“模型能否加载”，要看加载后还剩多少 KV 池

一个实用的容量公式：

```text
可用 KV 显存 ≈ 单卡显存 × util
              − 权重/卡
              − 激活与 CUDA Graph
              − 框架/通信缓冲
KV tokens ≈ 可用 KV 显存 / 每 token KV 字节数
```

## 2. 为什么是 0.93，不是 0.95

`gpu-memory-utilization=0.95` 时，vLLM 会把预算吃得很满：

- 权重
- profiling 激活
- CUDA Graph
- KV 池

CUDA Graph 捕获后，空闲可能只剩几十 MB。长 prefill 时，GDN/linear-attention kernel 的工作区不在 profiling 覆盖的形状内，申请显存就会 CUDA OOM，引擎进程直接死亡。

参考环境的安全线是 **0.93**，余量约 300MB。0.95 在短请求上可能看起来正常，但长上下文会暴露问题。

> 调参建议：不要用短请求验证显存安全线，至少跑一次长 prefill。

## 3. CPU offload 与 cgroup 限额

启用进程内 CPU offload 后，容易出现一类“看起来像 GPU OOM、实际是 cgroup OOM”的问题：

- offload 池分配在 vLLM 进程内
- 权重 checkpoint 加载也在同一进程
- 容器 `limits.memory` 如果只按“模型权重 + 一点余量”设置，启动阶段就会被 cgroup 杀掉

参考配置：

```text
limits.memory = 32GiB offload 池
              + 23.7GiB checkpoint
              + 运行时开销
              ≈ 72GiB
```

只改 offload 参数、不同步容器配额，启动期必然撞墙。

## 4. KV 缓存方案选型

参考环境实测过四条路线：

| 路线 | 结果 | 结论 |
|---|---|---|
| LMCache MP（Operator + Engine CR + DaemonSet） | 功能打通，但 server 的 GPU staging 随使用增长到约 2.7GiB/卡 | 与 16GB 卡结构性冲突，拆除 |
| LMCache 进程内连接器 | 混合 GDN 架构不兼容 | 放弃 |
| vLLM 原生进程内 offload | 零外部组件、零 GPU 占用，与前缀缓存协同 | 单机场景采用 |
| `--swap-space` | vLLM V1 已移除 | 不可用 |

结论：

- 多副本/跨实例场景才值得考虑共享 KV 层
- 单机双 16GB 优先用原生 offload
- 进程内 offload 随引擎重启清零，不解决跨重启持久化
- 引入任何第三方缓存组件前，先重算整卡显存账

## 5. 前缀缓存与 block size

混合模型的 unified block size 不一定是你熟悉的 16/32，而是由模型架构推导出来的更大值。参考实现是 **2096 tokens**。

前缀缓存以整块为粒度：

- 不足一个 block 的前缀不可缓存
- 测试样本必须大于 2 个 block
- 以 `usage.prompt_tokens` 的实测值为准，不能按字符数估算中文 token

一个合规的验证方法：

1. 构造共享前缀 > 2 个 block 的请求
2. 连续发两次
3. 看 `usage.prompt_tokens_details.cached_tokens`
4. 同时对比延迟变化

参考结果：7141 token 前缀，第二次命中 6288 token（88%），延迟 1.7s → 0.3s。

> 如果监控显示“缓存命中 0%”，先检查测试样本是否足够大，再怀疑功能坏了。

## 6. NUMA 与检索重排

CPU 推理的 embedding / rerank 很容易和 vLLM worker 抢 NUMA 本地内存。参考做法：

- embedding 服务绑定到 GPU 所在 NUMA 节点的物理核
- CPU 限额从 8 核提升到 16 核
- vLLM 主进程使用 `numactl --interleave=all`
- 用 `numactl --hardware` 核对拓扑后再改 CPU 列表

参考效果：

- 40 候选重排从超时降到 39.5s（60s 预算内）
- embedding 吞吐 23.9 → 29.4 items/s（+23%）
- 连续压测无 rerank degraded

详见 [numa-rerank-tuning.md](numa-rerank-tuning.md)。

## 7. 上下文压缩

长上下文场景要检查压缩配置是否真的生效。一个常见的静默失效条件是：

```text
context_window − max_output − headroom < 0
```

如果 headroom 默认值大于窗口余量，压缩逻辑可能永远不触发，但服务不会报错。

参考配置：

- `contextWindow = 131072`
- `thresholdRatio = 0.75`
- `headroomTokens = 8192`
- 触发点约 98,304 tokens

> 不要只看配置文件写了什么，要在日志/指标里确认压缩事件真的发生。

## 8. 可观测性

最小可用集合：

- vLLM：KV 占用、排队数、TTFT、E2E、吞吐
- embedding / rerank：请求速率、5xx、重排耗时
- 节点：CPU、内存、NUMA、磁盘
- GPU：利用率、显存、温度、功耗
- 告警：KV 高水位、持续排队、target down、rerank 5xx、内存不足、服务失联、GPU 温度

参考实现使用 15s 采样，把事件落到 SQLite，再由 webhook 转发到聊天工具。重点不是工具多，而是：

- 指标口径明确
- 告警能到达人
- 事件可回溯
- 故障后能补一条复盘记录

## 9. 失败模式清单

| 现象 | 常见根因 | 优先检查 |
|---|---|---|
| 启动期 Pod 被杀 | cgroup 限额 < offload + checkpoint | `kubectl describe pod`、OOMKilled |
| 长 prefill 引擎死亡 | 显存预算太满、kernel 工作区无余量 | 降 util、跑长请求 |
| 缓存命中 0% | 样本不足一个 block、指标口径不对 | block size、cached_tokens |
| 重排超时降级 | CPU 核数不足、NUMA 错位、候选太多 | taskset、CPU limit、候选数 |
| 重启后大量僵尸 Pod | device plugin 未就绪但 allocatable 已报 | 金丝雀准入、startup 顺序 |
| 集群内域名不解析 | hostNetwork 未配 dnsPolicy | `ClusterFirstWithHostNet` |

## 10. 经验总结

1. **先算账，再调参**：显存、内存、KV、并发一起算。
2. **区分 CUDA OOM 与 cgroup OOM**：一个看 GPU，一个看容器配额。
3. **不要用短请求验证长上下文**：问题只在长 prefill 出现。
4. **缓存测试样本要大于 block**：否则“0% 命中”是正确行为。
5. **第三方缓存先看显存账**：功能打通不等于能共存。
6. **单节点也要有准入检查**：GPU 可分配 ≠ GPU 健康。
