#!/usr/bin/env python3
"""RAG evaluation runner.

Input JSONL fields:
  - id: unique question id
  - question: question text
  - context: retrieved context to give the model
  - ground_truth: optional reference answer (used by the judge, not the model)

Usage:
  python3 run_eval.py questions.jsonl <model> answers.jsonl

Environment:
  EVAL_API_BASE: default http://127.0.0.1:8001/v1/chat/completions
"""

import json
import os
import sys
import time
import urllib.request

API = os.environ.get("EVAL_API_BASE", "http://127.0.0.1:8001/v1/chat/completions")
MODEL = sys.argv[2] if len(sys.argv) > 2 else "qwen3-35b"

SYSTEM = """You are a technical documentation QA assistant. Answer only from the provided reference material. Follow these rules:
1. Quote specifications exactly, including units. Do not round, convert, or invent values.
2. If the reference does not cover something, say "not specified in the provided material". Do not guess.
3. Do not transfer specifications between similarly named models or versions.
4. For selection questions, list the excluded candidates and the specific requirement each one fails.
5. End with a citation block: > Source: <document name>"""


def call_model(question, context):
    user = f"[REFERENCE]\n{context}\n\n[QUESTION]\n{question}"
    body = json.dumps(
        {
            "model": MODEL,
            "messages": [
                {"role": "system", "content": SYSTEM},
                {"role": "user", "content": user},
            ],
            "max_tokens": 4096,
            "temperature": 0.1,
        }
    ).encode()
    req = urllib.request.Request(
        API, data=body, headers={"Content-Type": "application/json"}
    )
    t0 = time.time()
    with urllib.request.urlopen(req, timeout=300) as resp:
        payload = json.load(resp)
    elapsed = time.time() - t0
    message = payload["choices"][0]["message"]
    answer = message.get("content") or message.get("reasoning") or ""
    if not message.get("content"):
        answer = "[REASONING_TRUNCATED] " + answer
    return answer, elapsed, payload["usage"]["completion_tokens"]


def main():
    if len(sys.argv) < 2:
        print("usage: run_eval.py <questions.jsonl> [model] [answers.jsonl]", file=sys.stderr)
        raise SystemExit(2)

    in_path = sys.argv[1]
    out_path = sys.argv[3] if len(sys.argv) > 3 else "answers.jsonl"
    cases = [json.loads(line) for line in open(in_path, encoding="utf-8") if line.strip()]

    with open(out_path, "a", encoding="utf-8") as out:
        for case in cases:
            if case.get("skip"):
                continue
            try:
                answer, elapsed, completion_tokens = call_model(
                    case["question"], case["context"]
                )
                status = "ok"
            except Exception as exc:  # noqa: BLE001 - keep the runner going
                answer, elapsed, completion_tokens, status = f"[ERROR] {exc}", 0, 0, "error"

            record = dict(
                case,
                model=MODEL,
                answer=answer,
                latency_s=round(elapsed, 1),
                completion_tokens=completion_tokens,
                status=status,
            )
            out.write(json.dumps(record, ensure_ascii=False) + "\n")
            out.flush()
            print(f"{case['id']} {status} {elapsed:.1f}s {completion_tokens}tok")


if __name__ == "__main__":
    main()
