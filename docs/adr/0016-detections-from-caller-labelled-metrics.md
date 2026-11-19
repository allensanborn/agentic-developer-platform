# 16. Detections come from caller-labelled gateway metrics and Cilium's drop counter

Status: accepted, 2026-11-19. Built (bead adp-0c0; follows adp-bio, which shipped tracing).

## Context

Traces (#13) and access logs record what happened. Nothing said something was wrong while it was happening. GTIG/Mandiant's Layer 5 (Nov 2026) is about that gap. Agentic intrusions arrive as valid identities moving at machine speed: ARTEX logged 27 events in 23 s, and a botnet made millions of model calls in a day on one leaked credential. Mandiant's prescription is to baseline per identity and alert on velocity, on bursts of refusals, and on egress to destinations a workload never needs. Anthropic adds that a blocked egress attempt is a signal even when nothing gets through.

## Decision

- agentgateway labels every Prometheus metric with `caller` = `jwt.sub` (`frontend.metrics.attributes`, supported in v1.7.0). Request and token counters become per-identity.
- Cilium exports `hubble_drop_total` by reason and source pod (ADR 0014).
- One Prometheus in `telemetry` scrapes both through DNS discovery. It has no Kubernetes API access, takes no ingress, and its egress is a CiliumNetworkPolicy naming the two targets.
- Rules (`platform/telemetry/alerts.yml`):
  - `GatewayTokenVelocity`: more than 20k tokens/min per caller.
  - `GatewayDenialBurst`: 10 or more 401/403/429 per caller and status within 1 minute.
  - `GatewayCallerDenied`: any 403 for a known caller.
  - `EgressPolicyDrop`: any `POLICY_DENIED` drop, by source pod.
- `promtool test rules` runs in `dagger call check`, so each rule is proven to fire on its case and stay quiet beside it, without a cluster. `smoke.sh` proves the live pipeline: a burst of `intern` refusals fires `GatewayDenialBurst` labelled with that caller, and the gateway probe's blocked egress fires `EgressPolicyDrop` for that pod.

## Consequences

- There is no Alertmanager, so nobody is paged. Firing alerts are read from the API. That's the next step once these should wake someone.
- `GatewayTokenVelocity` is a fixed ceiling, not a learned baseline. Two days of in-memory TSDB isn't history enough to baseline against.
- "Failover hides a rejected key" (an open risk) is not covered. The rejected upstream attempt is in traces, not in a metric with the provider's status.
- `smoke.sh` no longer reads Hubble's flow buffer for the egress drop. On a busy cluster the per-node ring (about 4k flows) evicted it within seconds. The counter behind `EgressPolicyDrop` is the durable record.
