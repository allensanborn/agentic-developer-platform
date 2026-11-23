"""Score the diagnosis graph's fix selection on cases.json by exact match (ADR 0011).

Runs the graph's own decide -> validate loop (erp/app/graph.py) on each case's context, so
the prompt, the validation and the one-retry rule are the ones that ship; only `gather` (the
database read) is replaced by the recorded context. A case is correct when the result is the
expected fix: same fix_type, same params. Prints a JSON summary; exits 1 below --min.

    AI_GATEWAY_URL=http://localhost:11434 DIAGNOSIS_ALIAS=llama3.2:3b \\
      python erp/eval/run.py --min 0.75
    python erp/eval/run.py --self-check   # the scoring itself, against two stand-in models

The model is called directly (Ollama's OpenAI API), not through the gateway: this tests the
graph and the prompt, not the platform's routing. temperature 0, seed 0 (graph.chat).
"""

import argparse
import json
import os
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE.parent / "app"))
os.environ.setdefault("AI_GATEWAY_TOKEN_FILE", "/dev/null")  # Ollama ignores the bearer token

import graph  # noqa: E402

CASES = json.loads((HERE / "cases.json").read_text())


def diagnose(case: dict) -> dict:
    s = {"rule": case["rule"], "key": case["key"], "context": case["context"]}
    while True:
        s.update(graph.decide(s))
        s.update(graph.validate(s))
        if graph.after_validate(s) == graph.END:
            return s


def score(cases: list) -> dict:
    rows = []
    for case in cases:
        s = diagnose(case)
        got = s.get("result") or {}
        outcome = ("correct" if got and {k: got.get(k) for k in case["expect"]} == case["expect"]
                   else "rejected" if s.get("error") else got.get("kind") == "recommendation" and "recommendation" or "wrong_fix")
        rows.append({"id": case["id"], "outcome": outcome, "answers": s.get("answers"), "tokens": s.get("tokens", 0),
                     "got": got if outcome != "correct" else None})
    n = len(rows)
    count = {o: sum(r["outcome"] == o for r in rows) for o in ("correct", "wrong_fix", "recommendation", "rejected")}
    return {"model": os.environ.get("DIAGNOSIS_ALIAS", graph.ALIAS), "cases": n,
            **{f"{o}_rate": round(c / n, 3) for o, c in count.items()},
            "tokens": sum(r["tokens"] for r in rows), "misses": [r for r in rows if r["outcome"] != "correct"]}


def self_check() -> None:
    """The scoring against two stand-ins: an oracle must score 1.0, a wrong answerer 0.0."""
    real = graph.chat
    try:
        expect = iter(c["expect"] for c in CASES)
        graph.chat = lambda *a: {"model": "oracle", "tokens": 1, "text": json.dumps({**next(expect), "evidence": "x"})}
        assert score(CASES)["correct_rate"] == 1.0, "oracle must score 1.0"
        wrong = {"kind": "fix", "fix_type": "set_invoice_total_from_lines", "params": {}}
        graph.chat = lambda *a: {"model": "wrong", "tokens": 1, "text": json.dumps(wrong)}
        totals = sum(c["expect"] == wrong for c in CASES)
        assert score(CASES)["correct_rate"] == round(totals / len(CASES), 3), "a fixed answer scores only its own cases"
        graph.chat = lambda *a: {"model": "junk", "tokens": 1, "text": "not json"}
        r = score(CASES)
        assert r["correct_rate"] == 0.0 and r["rejected_rate"] == 1.0, "junk is rejected, never correct"
    finally:
        graph.chat = real
    print("eval self-check ok")


if __name__ == "__main__":
    p = argparse.ArgumentParser()
    p.add_argument("--min", type=float, default=0.0, help="fail when correct_rate is below this")
    p.add_argument("--self-check", action="store_true")
    a = p.parse_args()
    if a.self_check:
        self_check()
        sys.exit(0)
    result = score(CASES)
    print(json.dumps(result, indent=1))
    sys.exit(0 if result["correct_rate"] >= a.min else 1)
