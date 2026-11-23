# 21. Fence probes run on a schedule, and a stale probe is an alert

Status: proposed, 2026-11-23. Not built.

## Context

Every control here names a check, and every deny check keeps an allow check beside it. Those checks live in `scripts/smoke.sh` and run when a person runs them. Between runs, a policy edit, a CNI restart or a chart bump can open a fence and nothing notices. `scripts/sandbox-up.sh` already has to restore Cilium mounts after restarting a node, which is the kind of event that breaks a fence quietly.

OpenAI's reference architecture for supervised investigations (2026-11-09) runs a preflight before each investigation: one write inside the workspace and one outside, one request to an approved host and one to a host outside the allowlist, each confirmed in logs the agent cannot write.

## Decision (proposed)

- The deny-and-allow pairs for the three fences that fail open are extracted from `smoke.sh` into a `fence-probe` CronJob: identity (no token and wrong audience get 401, a valid token gets 200), entitlement (a probe identity gets 403 on `smart` and 200 on `fast`), and egress (a direct call to a model and to the internet is blocked, the gateway is reachable).
- The probe has its own ServiceAccount, allowed `fast` and nothing else, in its own namespace under the tenant network policy.
- It exports one gauge per fence with the time of the last pass. Two alert rules: a probe failed, and a probe has not passed within three intervals.
- `smoke.sh` calls the same probe script, so there is one copy of each check.

## Alternatives considered

- **Gate every run on a fresh preflight**, as the guide does. Correct for a supervised investigation that a person starts. Here runs are started by triggers, and a preflight per run would multiply model calls. Scheduled probes plus an alert give the same evidence at a fixed cost. A controller can still refuse to start a run while the alert is firing; leave that until a tenant needs it.
- **Leave it in `smoke.sh` and run that from cron on a laptop.** It needs a kubeconfig with cluster-wide rights sitting on a schedule.

## Consequences

- A new principal in `boundary_register.yaml`.
- The egress deny probe fires `EgressPolicyDrop` (ADR 0016) every interval. The rule must exclude the probe's pod, and the probe's own failure alert must cover what that exclusion hides.
- An allow that fails is as loud as a deny that passes, so a broken probe cannot read as a working fence.
- Proof: `promtool` tests for both rules, and a smoke check that deletes one NetworkPolicy and sees the probe go red within one interval, then restores it.
