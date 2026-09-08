#!/usr/bin/env python3
"""Replay one immutable prompt corpus against optimization candidates.

`prepare` is run once against the stock llama-server tokenizer. `llama` uses
llama-server's native endpoint and server timings. `openai` supports candidates
(such as Halogen) that expose only OpenAI completions; its rates are explicitly
client-derived and are not mixed silently with engine timings.
"""
from __future__ import annotations

import argparse
import json
import sys
import time
import urllib.request
from pathlib import Path

# Keep prompt construction and native llama measurement identical to baseline.
from benchmark import Client, completion, corpus_for


def write_record(fp, record):
    line = json.dumps(record, sort_keys=True)
    print(line, flush=True)
    fp.write(line + "\n")
    fp.flush()


def prepare(args):
    client = Client(args.base)
    cases = []
    for size in [int(x) for x in args.sizes.split(",") if x]:
        reps = args.reps if size <= args.repeat_through else 1
        for rep in range(reps):
            tag = f"cold-{size}-r{rep}"
            prompt, n = corpus_for(client, size, f"fixed-optimization-{tag}")
            cases.append({"tag": tag, "target_tokens": size,
                          "actual_tokens": n,
                          "bytes": len(prompt.encode()), "prompt": prompt})
    payload = {"format": 1, "tokenizer_source": args.base,
               "created_unix": time.time(), "cases": cases}
    Path(args.corpus).write_text(json.dumps(payload, indent=2) + "\n")
    print(f"wrote {args.corpus} ({len(cases)} cases)", file=sys.stderr)


def openai_completion(base, prompt, predict, drafter):
    body = {"model": "benchmark", "prompt": prompt, "max_tokens": predict,
            "temperature": 0, "seed": 424242, "stream": True,
            "stream_options": {"include_usage": True}}
    if drafter:
        body["drafter"] = drafter
    req = urllib.request.Request(
        base.rstrip("/") + "/v1/completions",
        data=json.dumps(body, separators=(",", ":")).encode(),
        headers={"content-type": "application/json"}, method="POST")
    started = time.time()
    t0 = time.perf_counter()
    first = None
    text = []
    usage = {}
    finish_reason = None
    with urllib.request.urlopen(req, timeout=7200) as response:
        for raw in response:
            line = raw.decode("utf-8", "replace").strip()
            if not line.startswith("data: ") or line == "data: [DONE]":
                continue
            event = json.loads(line[6:])
            if event.get("usage"):
                usage = event["usage"]
            choices = event.get("choices") or []
            if choices:
                chunk = choices[0].get("text") or ""
                if chunk:
                    if first is None:
                        first = time.perf_counter() - t0
                    text.append(chunk)
                finish_reason = choices[0].get("finish_reason") or finish_reason
    wall = time.perf_counter() - t0
    generated = usage.get("completion_tokens")
    # This is a client estimate, not an engine timing. The first token arrives
    # at TTFT; remaining tokens occupy the post-first-token wall interval.
    decode_tps = None
    if generated and generated > 1 and first is not None and wall > first:
        decode_tps = (generated - 1) / (wall - first)
    return {"kind": "completion", "timing_source": "client-openai",
            "started_unix": started, "wall_s": wall, "ttft_s": first,
            "prompt_n": usage.get("prompt_tokens"),
            "tokens_predicted": generated, "decode_tps_estimate": decode_tps,
            "finish_reason": finish_reason, "content": "".join(text)}


def replay(args):
    corpus = json.loads(Path(args.corpus).read_text())
    out = Path(args.output)
    out.parent.mkdir(parents=True, exist_ok=True)
    native = args.mode == "llama"
    client = Client(args.base) if native else None
    with out.open("a", encoding="utf-8") as fp:
        health_path = "/props" if native else "/health"
        with urllib.request.urlopen(args.base.rstrip("/") + health_path,
                                    timeout=30) as response:
            health = json.loads(response.read())
        write_record(fp, {"kind": "metadata", "label": args.label,
                          "base": args.base, "mode": args.mode,
                          "unix": time.time(), "health": health})
        for case in corpus["cases"]:
            write_record(fp, {k: case[k] for k in
                              ("tag", "target_tokens", "actual_tokens", "bytes")}
                         | {"kind": "payload"})
            if native:
                result = completion(client, case["prompt"], 0, args.predict,
                                    case["tag"], cache_prompt=False)
                result["timing_source"] = "server-llama"
            else:
                result = openai_completion(args.base, case["prompt"],
                                           args.predict, args.drafter)
                result["tag"] = case["tag"]
            write_record(fp, result)
    print(f"wrote {out}", file=sys.stderr)


def main():
    p = argparse.ArgumentParser()
    p.add_argument("mode", choices=("prepare", "llama", "openai"))
    p.add_argument("--base", default="https://qwen-next.gisi.network")
    p.add_argument("--corpus", default="raw/optimization-corpus.json")
    p.add_argument("--label", default="fixed-corpus")
    p.add_argument("--output", default="raw/candidate.jsonl")
    p.add_argument("--sizes", default="256,1024,4096,20000,30000")
    p.add_argument("--reps", type=int, default=3)
    p.add_argument("--repeat-through", type=int, default=4096)
    p.add_argument("--predict", type=int, default=64)
    p.add_argument("--drafter", default="")
    args = p.parse_args()
    if args.mode == "prepare":
        prepare(args)
    else:
        replay(args)


if __name__ == "__main__":
    main()
