# 24. ERP diagnosis has its own alias, with no small-model fallback

Status: accepted, 2026-11-24. Amends ADR 0018 (the host serves a second pinned model).

## Context

The ERP agent chose fixes through `smart`: OpenRouter, then the host's `llama3.2:3b`, then the in-cluster 3B. The eval (ADR 0011) scored fix selection on 12 seeded discrepancies on the host GPU: `llama3.2:3b` 4 of 12 (it always recomputes the invoice total, even when one line's price or quantity is wrong), `llama3.1:8b` 9 of 12. Without a provider key, `smart` therefore proposes a wrong fix most of the time on line-level errors. The controller's check and the approver catch it, but every wrong proposal costs an approver's time.

Options weighed: leave ERP on `smart`; point `smart` at the 8B (rejected by ADR 0018: the 8B swapped 7.7 GB under a full-stack smoke run); decide after the hosted path has a key and an eval score (adp-8ms); a separate alias.

## Decision

- A `diagnose` alias: OpenRouter, then `llama-8b-host` (`llama3.1:8b` on the host's Ollama, same loopback fence and digest pinning as ADR 0018, `versions.env` `HOST_DIAGNOSIS_MODEL`). Only `erp-agent` may reach `llama-8b-host`.
- No in-cluster fallback. When both are down the call fails and the workflow activity retries; that is better than a proposal that is wrong two times in three.
- `erp/app/graph.py` defaults `DIAGNOSIS_ALIAS` to `diagnose`. `smart` is unchanged for the research agent.

## Consequences

- **We give up** ERP diagnosis that still answers with only the cluster up, **to get** proposals that are right most of the time.
- The 8B loads only when the ERP agent diagnoses with a real model; the default `erp-smoke.sh` uses `scripted` and never loads it. When it does load, the host pays the memory ADR 0018 measured (about 5 GB beside the VM, and swap under the full stack).
- The hosted model behind `diagnose` (`openai/gpt-oss-20b:free`) has no eval score yet. Running the eval against it needs the key (adp-8ms).

## Flips if

- The hosted model scores below the 8B on the eval. Then put the 8B first.
- A full-stack run with a real diagnosis swaps enough to stall the cluster. Then hosted-only for `diagnose`, or a machine with more memory.
- A smaller model reaches the 8B's score on the eval. Then it replaces the 8B.
