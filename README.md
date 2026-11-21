# LLM Inference Platform

> 单节点双卡 LLM 推理平台工程模板：vLLM + Kubernetes + KV 缓存分层 + 可观测性 + 生命周期脚本。

这是一个**脱敏后的参考实现**，用于在 2×16GB GPU 的单节点上部署 35B 级 MoE 模型。仓库保留平台工程中可复用的 YAML、systemd 生命周期、容量核算、排障记录和评测工具；所有环境特定数据与真实凭据均已移除。

> 这不是开箱即用的生产发行版。硬件型号、模型路径、端口和资源参数都需要按你的环境调整。

## 架构

```text
Agent / RAG UI
      │
      ├── knowledge tool ──► embedding / rerank service (:7997)
      │
      └── OpenAI-compatible API ──► vLLM (:8001)
                                      │
                                      └── 2× GPU, tensor parallel = 2

Prometheus ──► vLLM / embedding / node / GPU exporters
     │
     └── Alertmanager ──► webhook / chat alert
```

更完整的部署视图和请求流见 [docs/architecture.md](docs/architecture.md)。

## 组件

- **推理服务**：vLLM 0.31，Qwen3.6-35B-A3B-AWQ，TP2，FP8 KV，prefix caching
- **KV 缓存**：GPU 池 + 32GiB 进程内 CPU offload + 可选 SSD 二级缓存
- **容器平台**：Kubernetes Deployment，hostNetwork，GPU 独占，startup/readiness/liveness probe
- **生命周期**：systemd `Type=oneshot + RemainAfterExit`，开机有序拉起、关机摘除、金丝雀 GPU 准入门
- **可观测性**：Prometheus + Grafana + Alertmanager + 轻量采集器（SQLite 事件库）
- **评测**：RAG 问答评测脚本与合成样例，支持替换为自己的非敏感数据集

## 目录

```text
llm-inference-platform/
├── yaml/
│   ├── qwen3-35b-deployment.yaml   vLLM 主服务
│   ├── qwen3-35b-nodeport.yaml     NodePort Service
│   └── embedding-deployment.yaml   embedding / rerank 服务
├── systemd/
│   ├── qwen3-35b.service           生命周期单元
│   ├── manage.sh                   start / stop / verify 逻辑
│   └── README.md                   安装与设计说明
├── docs/
│   ├── architecture.md             部署视图 + 请求流
│   ├── operations-notes.md         容量、显存、KV、OOM 与缓存经验
│   └── numa-rerank-tuning.md       NUMA 绑定与重排优化记录
├── eval/
│   ├── run_eval.py                 评测执行脚本
│   ├── judge_prompt.md             评分提示词
│   ├── questions/sample.jsonl      合成样例
│   └── contexts/                   合成检索上下文
├── .gitignore
├── LICENSE
└── README.md
```

## 快速开始

### 1. 前置条件

- 单节点 Kubernetes，已安装 NVIDIA device plugin
- 2 张 16GB GPU，驱动与 CUDA 可用
- 模型权重放在宿主机 `/data/models/`（路径可按需修改）
- 能拉取 `vllm/vllm-openai:v0.31.0` 与 `michaelf34/infinity:latest`，或提前导入本地镜像

### 2. 调整 YAML

至少确认这些值：

- `yaml/qwen3-35b-deployment.yaml`：模型路径、`--max-model-len`、`--max-num-seqs`、GPU 数量、内存限额
- `yaml/embedding-deployment.yaml`：CPU 绑定核数、模型缓存路径、端口
- `yaml/qwen3-35b-nodeport.yaml`：`nodePort`

如果集群有多个 GPU 节点，给节点打标签并在 Deployment 中加 `nodeSelector`，或取消注释 `nodeName` 并填入你的 GPU 节点名。

### 3. 部署

```bash
kubectl create namespace llm-serving
kubectl apply -f yaml/qwen3-35b-deployment.yaml
kubectl apply -f yaml/qwen3-35b-nodeport.yaml
kubectl apply -f yaml/embedding-deployment.yaml
kubectl -n llm-serving get deploy,pod,svc
```

### 4. 可选：systemd 生命周期托管

```bash
sudo mkdir -p /opt/llm-inference-platform
sudo cp -r yaml systemd docs eval README.md /opt/llm-inference-platform/
sudo cp systemd/qwen3-35b.service /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now qwen3-35b.service
```

安装说明与设计取舍见 [systemd/README.md](systemd/README.md)。

### 5. 评测

```bash
python3 eval/run_eval.py eval/questions/sample.jsonl qwen3-35b /tmp/answers.jsonl
```

`eval/questions/sample.jsonl` 是合成数据，仅用于演示格式；不要提交真实业务问答。

## 关键设计

### 显存容量核算

在 2×16GB 上跑 35B MoE，核心不是“能不能加载”，而是“加载后还剩多少 KV 池”：

- 权重约 11.3GB/卡，FP8 KV 约 10KB/token
- 参考配置的 KV 池约 438K tokens，可支撑 2–3 路 128K 会话
- `gpu-memory-utilization=0.93` 是参考安全线；0.95 会在长 prefill 的 GDN kernel 工作区触发 CUDA OOM
- 容器内存限额要覆盖 CPU offload 池 + checkpoint + 运行时开销，参考值 72GiB

### KV 缓存分层

- 优先使用 vLLM 原生 prefix caching
- 需要 CPU 兜底时，使用进程内 offload（零外部组件、零 GPU 占用）
- LMCache MP 架构在多副本/跨实例场景有价值，但在 2×16GB 单机上，server 的 GPU staging 会与 vLLM 争显存，属于结构性冲突
- 进程内 offload 随引擎重启清零，不解决跨重启持久化

### 前缀缓存测试

混合模型的 unified block size 可能不是常见的 16/32，而是由架构推导出的更大值（参考实现为 2096 tokens）。**不足一个 block 的前缀不可缓存**，测试样本必须大于 2 个 block，并以 `usage.prompt_tokens` 实测值为准，不能按字符数估算。

### NUMA 与重排

embedding / rerank 是 CPU 推理，容易和 vLLM worker 抢 NUMA 本地内存。参考做法：

- embedding 服务绑定到 GPU 所在 NUMA 节点的物理核
- CPU 限额从 8 核提升到 16 核
- vLLM 主进程使用 `numactl --interleave=all` 均分主机内存
- 重排 40 个候选的耗时从超时降到 39.5s（60s 预算内）

详见 [docs/numa-rerank-tuning.md](docs/numa-rerank-tuning.md)。

### 可观测性

- vLLM：KV 占用、排队、TTFT、E2E、吞吐
- embedding / rerank：请求速率、5xx、重排耗时
- 节点：CPU、内存、NUMA、磁盘
- GPU：利用率、显存、温度、功耗
- 告警：KV 高水位、持续排队、target down、rerank 5xx、内存不足、服务失联、GPU 温度

## 适用边界

- 单节点、单副本，无高可用；宿主机故障 = 平台中断
- 适合内部知识库、Agent、RAG 等 2–3 路长上下文场景
- 不适合多租户、大规模并发或需要跨节点调度的场景
- 生产使用前请补充：镜像固定 digest、资源配额、网络策略、备份、密钥管理、升级与回滚流程

## 脱敏说明

本仓库是原平台资产的公开版本：

- 删除全部业务问答数据与评测报告
- 删除明文凭据与内部账号信息
- 内部主机名、路径、告警渠道替换为通用示例
- `eval/` 只保留合成样例，避免把真实 RAG 数据带入公开历史

如果你要基于本仓库二次开发，请先确认你有权使用相关模型、镜像和硬件配置。

## License

MIT，见 [LICENSE](LICENSE)。
