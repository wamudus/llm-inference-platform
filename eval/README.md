# 评测工具

这是一个最小可复跑的 RAG 质量回归框架。

## 目的

换模型、换 chunk 策略、换 prompt、换 rerank 版本时，用同一套问题、同一份上下文、同一套评分标准做 A/B，而不是凭感觉判断“好像变好了”。

## 文件

- `run_eval.py`：读取 JSONL，调用 OpenAI 兼容接口，输出答案与延迟
- `judge_prompt.md`：独立评分提示词
- `questions/sample.jsonl`：3 条合成样例，演示参数查询、选型对比、否定/边界
- `contexts/`：合成检索上下文，和 sample 对应

## 输入格式

每行一个 JSON：

```json
{
  "id": "SAMPLE-01",
  "question": "...",
  "context": "...",
  "ground_truth": "...",
  "source_doc": "doc-name",
  "category": "参数查询"
}
```

`context` 是检索后送给模型的固定上下文，保证 A/B 同条件；`ground_truth` 只给评分员，不给模型。

## 跑评测

```bash
python3 eval/run_eval.py eval/questions/sample.jsonl qwen3-35b /tmp/answers.jsonl
```

如果服务不在本机：

```bash
EVAL_API_BASE=http://<host>:8001/v1/chat/completions \
  python3 eval/run_eval.py eval/questions/sample.jsonl qwen3-35b /tmp/answers.jsonl
```

## 评分

把 `answers.jsonl`、`questions/sample.jsonl` 和 `judge_prompt.md` 交给独立评分模型，要求它按 JSON 输出逐题分数。建议：

- 评分模型和被测模型不同
- 评分时不给模型看模型名
- 至少两人/两次盲评，避免单次波动
- 重点看失败题的类型，不只看平均分

## 注意

- 本目录的样例是合成的，不含任何真实产品资料。
- 不要把自己的业务问答、业务需求、业务规格提交到公开仓库。
- 如果要公开评测结果，先脱敏题目、上下文和答案中的型号/业务信息。
