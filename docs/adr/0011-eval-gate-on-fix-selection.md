# 11. Evaluate fix selection by exact match, gated in CI

Status: accepted, 2026-11-12. Built 2026-11-24 (`dagger call eval`, `erp/eval/`).

## Context

With detection deterministic (ADR 0005), what the model decides is which fix type and parameters resolve a discrepancy. A seed script that plants discrepancies knows the correct fix for each.

## Decision

- A seeded set of discrepancies, each with its correct fix, is scored by code: correct-fix rate, check-rejected rate, recommendation rate, tokens.
- The eval runs in the Dagger pipeline against a model service container and fails below a threshold.
- Temperature 0, a fixed seed set, and a threshold below the measured rate with margin.
- Scoring each gateway model alias on the same set is a cluster script, since the hosted path needs a key CI should not hold.

## Consequences

- A prompt regression cannot merge.
- CI calls the model directly, without agentgateway, so it tests the graph and prompt, not the platform's routing.
- A small model on shared CPUs is slow and variable; the threshold has to allow for it.
- No model grades another model's output.

## As built (2026-11-24)

- 12 seeded cases (`erp/eval/make_cases.py`), four each of a wrong total, a wrong line price and a wrong line quantity. Each case's context is what `gather` would read, with the total left as detection would find it.
- `erp/eval/run.py` runs the graph's own `decide` → `validate` loop, scores exact match on `fix_type` and params, and has a `--self-check` (an oracle scores 1.0, a fixed answer scores only its own cases, junk is rejected).
- Measured on the host GPU, temperature 0: `llama3.2:1b` 0.0 (invalid JSON), `llama3.2:3b` 0.33 (always recomputes the total), `llama3.1:8b` 0.75. Flagging the anomalous line in the context did not move the 3B.
- The gate is in two parts, because no model that runs on CI's CPUs in reasonable time is good enough to be the bar:
  - CI runs a floor of 0.25 on `llama3.2:3b` (`dagger call eval`: pulled into an Ollama service container, manifest checked against its digest). The floor catches a broken prompt or output format, not a weaker model. On CPU it scored 0.333, the same as on the GPU, and took about 25 minutes, so it is its own workflow (`.github/workflows/eval.yml`), run when `erp/app`, `erp/eval`, `models.yaml` or `.dagger` change. `dagger call check` runs only the scoring's self-check.
  - The bar is 0.65 on the 8B, run before merging a prompt or model change: `dagger call eval --ollama tcp://localhost:11434 --model llama3.1:8b --min 0.65`, against the host's GPU server. It is a manual step, not a required check.
