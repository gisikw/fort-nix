#!/usr/bin/env python3
"""Reproducible llama-server benchmark for lordhenry's Qwen3.8-Flash-Next.

Uses only Python's standard library. Run, for example:
  nix shell nixpkgs#python3 -c python benchmark.py suite --label dual
  nix shell nixpkgs#python3 -c python benchmark.py parity --label dual

Results are JSON Lines. The native /completion endpoint is used because it is
llama-server's only API with explicit id_slot affinity.
"""
from __future__ import annotations

import argparse
import concurrent.futures
import json
import os
import statistics
import sys
import threading
import time
import urllib.error
import urllib.request
from pathlib import Path

DEFAULT_BASE = "https://qwen-next.gisi.network"
# Deliberately prose/code/log shaped, rather than one repeated token. Indexes
# keep lines distinct and avoid an unrealistically compressible byte payload.
LINE = (
    "Turn {i}: The user reports that worker task-{j} returned HTTP 503 after "
    "the deployment. We inspect latency_ms={lat}, compare the service log, "
    "check `systemctl status example`, and preserve unrelated processes. "
    "The assistant explains the evidence, marks assumptions, and proposes one "
    "reversible next step before changing production.\n"
)

class Client:
    def __init__(self, base: str, timeout: float = 7200):
        self.base = base.rstrip("/")
        self.timeout = timeout

    def get(self, path: str):
        with urllib.request.urlopen(self.base + path, timeout=self.timeout) as r:
            return json.loads(r.read())

    def post(self, path: str, obj: dict, stream: bool = False):
        data = json.dumps(obj, separators=(",", ":")).encode()
        req = urllib.request.Request(
            self.base + path, data=data,
            headers={"Content-Type": "application/json"}, method="POST")
        start = time.perf_counter()
        with urllib.request.urlopen(req, timeout=self.timeout) as r:
            if not stream:
                body = json.loads(r.read())
                return body, time.perf_counter() - start, None
            first = None
            final = None
            content_parts = []
            # llama-server emits SSE as one JSON object per `data:` line.
            for raw in r:
                line = raw.decode("utf-8", "replace").strip()
                if not line.startswith("data: "):
                    continue
                payload = line[6:]
                if payload == "[DONE]":
                    continue
                event = json.loads(payload)
                if event.get("content"):
                    content_parts.append(event["content"])
                if first is None and (event.get("content") or event.get("tokens")):
                    first = time.perf_counter() - start
                final = event
            final = final or {}
            final["content"] = "".join(content_parts)
            return final, time.perf_counter() - start, first

    def tokenize(self, text: str) -> list[int]:
        body, _, _ = self.post("/tokenize", {"content": text})
        return body["tokens"]


def corpus_for(client: Client, target: int, salt: str) -> tuple[str, int]:
    """Create realistic text with no more than target tokenizer tokens."""
    chunks = [f"Benchmark trajectory {salt}. Treat all following records as conversation history.\n"]
    i = 0
    # Typical line is ~60 tokens; overshoot cheaply, then binary-search chars.
    while i < target // 35 + 80:
        chunks.append(LINE.format(i=i, j=(i * 7919) % 100003, lat=17 + (i * 37) % 1900))
        i += 1
    text = "".join(chunks)
    toks = client.tokenize(text)
    if len(toks) <= target:
        return text, len(toks)
    lo, hi = 1, len(text)
    best_text, best_n = text[:1], len(client.tokenize(text[:1]))
    while lo <= hi:
        mid = (lo + hi) // 2
        # End at whitespace so the final token is not an artificial fragment.
        cut = text.rfind(" ", 0, mid)
        if cut < 1:
            cut = mid
        candidate = text[:cut]
        n = len(client.tokenize(candidate))
        if n <= target:
            best_text, best_n = candidate, n
            lo = mid + 1
        else:
            hi = mid - 1
    return best_text, best_n


def completion(client: Client, prompt: str, slot: int, predict: int,
               tag: str, cache_prompt: bool = True) -> dict:
    request = {
        "prompt": prompt, "id_slot": slot, "cache_prompt": cache_prompt,
        "n_predict": predict, "temperature": 0.0, "seed": 424242,
        "stream": True,
    }
    before = time.time()
    body, wall, ttft = client.post("/completion", request, stream=True)
    timings = body.get("timings", {})
    return {
        "kind": "completion", "tag": tag, "started_unix": before,
        "slot": slot, "input_tokens_local": len(client.tokenize(prompt)),
        "wall_s": wall, "ttft_s": ttft,
        "tokens_evaluated": body.get("tokens_evaluated"),
        "tokens_cached": body.get("tokens_cached"),
        "tokens_predicted": body.get("tokens_predicted"),
        "cache_n": timings.get("cache_n"),
        "prompt_n": timings.get("prompt_n"),
        "prompt_ms": timings.get("prompt_ms"),
        "prompt_tps": timings.get("prompt_per_second"),
        "decode_ms": timings.get("predicted_ms"),
        "decode_tps": timings.get("predicted_per_second"),
        "stop_type": body.get("stop_type"),
        "truncated": body.get("truncated"),
        "content": body.get("content", ""),
    }


def emit(fp, record: dict):
    line = json.dumps(record, sort_keys=True)
    print(line, flush=True)
    fp.write(line + "\n")
    fp.flush()


def run_suite(args, client: Client, fp):
    props = client.get("/props")
    emit(fp, {"kind": "metadata", "label": args.label, "base": args.base,
              "unix": time.time(), "props": {
                  "total_slots": props.get("total_slots"),
                  "n_ctx": props.get("default_generation_settings", {}).get("n_ctx"),
                  "model_alias": props.get("model_alias"),
                  "model_ftype": props.get("model_ftype")}})
    sizes = [int(x) for x in args.sizes.split(",") if x]
    for size in sizes:
        reps = args.reps if size <= args.repeat_through else 1
        for rep in range(reps):
            # A distinct first line forces a cold/full prefill despite --cache-prompt.
            prompt, n = corpus_for(client, size, f"{args.label}-cold-{size}-{rep}-{time.time_ns()}")
            emit(fp, {"kind": "payload", "tag": f"cold-{size}-r{rep}",
                      "target_tokens": size, "actual_tokens": n,
                      "bytes": len(prompt.encode())})
            emit(fp, completion(client, prompt, rep % props["total_slots"],
                                args.predict, f"cold-{size}-r{rep}"))


def run_parity(args, client: Client, fp):
    props = client.get("/props")
    if props.get("total_slots", 0) < 2:
        raise SystemExit("parity scenario requires the pre-change two-slot deployment")
    nonce = f"{args.label}-{time.time_ns()}"
    main, main_n = corpus_for(client, args.main_tokens, nonce + "-main")
    shadow, shadow_n = corpus_for(client, args.shadow_tokens, nonce + "-shadow")
    emit(fp, {"kind": "metadata", "label": args.label, "scenario": "parity",
              "main_tokens": main_n, "shadow_tokens": shadow_n,
              "unix": time.time(), "total_slots": props.get("total_slots")})

    # Establish both resident trajectories. Run concurrently to also measure
    # scheduler contention during two large, independent prefills.
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        fs = [ex.submit(completion, client, main, 0, 1, "parity-seed-main"),
              ex.submit(completion, client, shadow, 1, 1, "parity-seed-shadow")]
        for f in fs:
            emit(fp, f.result())

    user_turn, user_n = corpus_for(client, args.turn_tokens, nonce + "-new-user")
    main_extended = main + "\n<|im_start|>user\n" + user_turn + "<|im_end|>\n<|im_start|>assistant\n"
    main_result = completion(client, main_extended, 0, args.response_tokens,
                             "parity-main-new-turn")
    emit(fp, main_result)
    assistant = main_result.get("content", "")
    assistant_n = len(client.tokenize(assistant))
    tail = ("\n<|im_start|>user\n" + user_turn + "<|im_end|>\n"
            "<|im_start|>assistant\n" + assistant + "<|im_end|>\n")
    shadow_extended = shadow + tail
    emit(fp, {"kind": "parity-tail", "user_tokens": user_n,
              "assistant_tokens": assistant_n,
              "tail_tokens": len(client.tokenize(tail))})

    # Sequential: coordinator awaits shadow update before accepting the next
    # turn. This directly measures the serialized unavailable interval.
    emit(fp, completion(client, shadow_extended, 1, 1,
                        "parity-shadow-prefetch-serialized"))
    next_turn = "\n<|im_start|>user\nPlease summarize the safest next action in one sentence.<|im_end|>\n<|im_start|>assistant\n"
    emit(fp, completion(client, main_extended + assistant + next_turn, 0, 16,
                        "parity-main-after-serialized-shadow"))

    # Re-seed slot 1 with another stable 20k prefix so the same appended tail
    # must be evaluated again. Start a main request shortly after shadow work;
    # both requests can occupy slots, while the single GPU may contend/batch.
    shadow2, _ = corpus_for(client, args.shadow_tokens, nonce + "-shadow2")
    emit(fp, completion(client, shadow2, 1, 1, "parity-seed-shadow2"))
    barrier = threading.Barrier(2)
    def shadow_job():
        barrier.wait()
        return completion(client, shadow2 + tail, 1, 1,
                          "parity-shadow-prefetch-concurrent")
    def main_job():
        barrier.wait()
        time.sleep(args.concurrent_delay)
        return completion(client, main_extended + assistant + next_turn + " Again.",
                          0, 16, "parity-main-during-shadow")
    with concurrent.futures.ThreadPoolExecutor(max_workers=2) as ex:
        fshadow, fmain = ex.submit(shadow_job), ex.submit(main_job)
        emit(fp, fshadow.result())
        emit(fp, fmain.result())


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=("suite", "parity"))
    p.add_argument("--base", default=os.environ.get("QWEN_BASE", DEFAULT_BASE))
    p.add_argument("--label", required=True)
    p.add_argument("--output")
    p.add_argument("--sizes", default="256,1024,4096,20000,30000")
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--repeat-through", type=int, default=4096)
    p.add_argument("--predict", type=int, default=64)
    p.add_argument("--main-tokens", type=int, default=30000)
    p.add_argument("--shadow-tokens", type=int, default=20000)
    p.add_argument("--turn-tokens", type=int, default=128)
    p.add_argument("--response-tokens", type=int, default=128)
    p.add_argument("--concurrent-delay", type=float, default=0.25)
    args = p.parse_args()
    out = Path(args.output or f"raw/{args.label}-{args.mode}-{int(time.time())}.jsonl")
    out.parent.mkdir(parents=True, exist_ok=True)
    client = Client(args.base)
    with out.open("a", encoding="utf-8") as fp:
        if args.mode == "suite": run_suite(args, client, fp)
        else: run_parity(args, client, fp)
    print(f"wrote {out}", file=sys.stderr)

if __name__ == "__main__":
    main()
