# 1. agentgateway as the single gateway

Status: accepted, 2026-11-10

## Context

Agents need model access without holding provider keys, with per-agent access rules, budgets, and routing between hosted and local models. Later they need the same for tools (MCP) and other agents (A2A).

## Options

- **Envoy AI Gateway on Envoy Gateway.** Built and verified first in this repo: JWT auth, per-route allow-lists, alias routing, failover. Two controllers. Token budgets need a Redis-backed rate-limit service. No MCP or A2A story.
- **LiteLLM.** Most provider coverage. Thoughtworks Radar vol. 35 holds it at Trial citing 25+ CVEs in 2026, and it was the target of a credential-theft compromise in March 2026. A Python proxy holding a master key is the wrong shape for the highest-value credential target on the platform.
- **agentgateway.** One data plane for LLM, MCP and A2A. Model catalogue with aliases, failover and per-model authorization as Kubernetes resources. Token budgets keyed on a JWT claim with no extra service. Radar: Assess.

## Decision

agentgateway v1.7.0, in Kubernetes mode with the Gateway API.

## Consequences

- One policy model and one component to harden for every kind of agent traffic.
- Every agentgateway CRD is `v1alpha1`; expect breaking changes on upgrade. `versions.env` pins it and `scripts/smoke.sh` is the upgrade test.
- Policies cannot attach to an alias, so access is declared on the concrete models behind it.
- The gateway takes JWKS inline or by URL, so `up.sh` snapshots the cluster's signing keys.
- Rate-limit buckets are per proxy replica. Running more than one replica multiplies each budget until a shared rate-limit service is added.
