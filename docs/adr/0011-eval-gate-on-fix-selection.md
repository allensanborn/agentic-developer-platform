# 11. Evaluate fix selection by exact match, gated in CI

Status: accepted, 2026-11-12. Not built yet.

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
