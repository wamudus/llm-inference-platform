# 检索管线：MinerU + infinity + DSH 知识库

离线 RAG 的检索侧管线：文档解析 → 分片 → 嵌入 → 检索 → 重排 → 本地 LLM 回答。
本文档覆盖检索侧（解析 + 嵌入 + 重排）的部署与排错；LLM 推理侧见 `architecture.md`。

## 全链路

```
PDF 上传
  ↓ ① MinerU 4.0.6        解析：PDF → 结构化 Markdown（表格/公式/版面保真）
  ↓ ② DSH 知识库插件       分片：切成 chunk
  ↓ ③ infinity bge-m3     嵌入：chunk → 向量
  ↓ 向量库
检索 → ④ infinity reranker 重排：bge-reranker-v2-m3
  ↓ ⑤ 本地 LLM             回答
```

三段分工不重叠：**MinerU 管"读得懂"（解析），DSH 管"怎么切"，infinity 管"找得到"（嵌入+重排）**。
以前的瓶颈在①：pdftotext 把规格表拍平成纯文本，后面做得再好也救不回。

## 为什么 MinerU 必须 4.0.6

DSH `dsh-knowledge` 插件（含最新 beta）的 mineru-local 适配器**只认 MinerU 4.0.6 的 V1 API**：

| 插件调用 | 4.0.6 | 4.2.x |
|---|---|---|
| `/v1/parse/jobs`、`/v1/uploads`、`/v1/files`、`/v1/tiers` | ✅ 匹配 | ❌ 改成 `/v1/tasks`，404 |

插件不升级 API 前，MinerU 只能钉 4.0.6。

## 部署

### MinerU venv（宿主机，uv 管理）

```bash
uv venv /data/mineru406-venv --python 3.11
source /data/mineru406-venv/bin/activate
uv pip install torch --index-url https://download.pytorch.org/whl/cu124
uv pip install mineru==4.0.6
mineru-models-download --tier standard --source modelscope   # MinerU2.5-Pro 1.2B GGUF
```

模型持久化在 `/root/.mineru`（deployment 挂载它）。

### 启动

由 `platfrom-manage.sh` 编排（见 `../systemd/`），或手动：

```bash
kubectl apply -f yaml/embedding-deployment.yaml   # 注意替换 ${EMBED_GPU_UUID}
```

DSH 插件配置（`$DSH_HOME/storages/knowledge.json` → `global.overrides`）：

```json
"documentProcessorProvider": "mineru-local",
"mineruLocalUrl": "http://127.0.0.1:30801",
"mineruTier": "standard"
```

改完重启 DSH 生效。

## GPU 共享（关键坑）

mineru 和 infinity 两个容器**共享一张卡**：

- `nvidia.com/gpu` 只注入**申请它的那个容器**（mineru）。infinity 若不显式声明，会默认看到**全部卡**并撞上别的负载（torch 默认 cuda:0）。
- **解法**：给 infinity 也设 `NVIDIA_VISIBLE_DEVICES=<同一张卡的 UUID>`。

## 性能

| 指标 | CPU | GPU |
|---|---|---|
| 检索（嵌入+重排） | 44.6 s | **0.12 s** |
| 规格书解析（7 页） | — | 15.9 s |

## 运维入口

| 服务 | 端点 |
|---|---|
| MinerU API | `:30801`（NodePort） |
| infinity | `127.0.0.1:7997`（hostPort） |

- 上传：`POST /knowledge/bases/{baseId}/documents`，body `{fileName, mimeType, contentBase64}`
- 检索：`POST /knowledge/search`，body `{query, topK}`
