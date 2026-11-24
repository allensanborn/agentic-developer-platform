# 22. One command suspends one identity, from outside the agent

Status: accepted, 2026-11-24. Built (`scripts/suspend.sh`), without the workflow step; see As built.

## Context

When an agent misbehaves, the options today are to wait for its token budget to return 429, to hand-edit `platform/gateway/models.yaml` and re-run `up.sh`, or to delete the deployment and lose the run. None is rehearsed, and none is checked by a test.

OpenAI's reference architecture for supervised investigations (2026-11-09) requires the operator to verify, before the first run, that they can stop the agent or cut its access from outside the agent, for use "if you lose monitoring, need to stop immediately, or can't confirm that the run has stopped".

## Decision (proposed)

`scripts/suspend.sh <identity>` and `scripts/resume.sh <identity>` do three things, in this order:

1. **Gateway.** Add the identity to a deny list that is evaluated before any allow-list. Every model and tool call from it gets 403.
2. **Network.** Apply a CiliumNetworkPolicy that denies all egress from that ServiceAccount's pods, so a workload that ignores the 403 still reaches nothing.
3. **Workflow.** Suspend the identity's running Dapr Workflow instances, so state is kept and a resumed run continues.

The script prints what it changed and what is still running. It does not delete anything.

## Alternatives considered

- **Delete the pod or scale to zero.** Loses in-memory work and, for a Deployment, the pod comes back.
- **Revoke the token.** ServiceAccount tokens cannot be revoked individually; they expire within 10 minutes.
- **Budget of zero.** Stops spending, not tool calls or egress.

## Consequences

- A suspended identity's token stays valid for up to 10 minutes and is useless at the gateway for that time.
- Under GitOps (`adp-m3l`) the deny list is a file in Git, and a commit is too slow for an emergency. The script stays as a documented break-glass path, and the controller must be told to tolerate it until the matching commit lands.
- Suspension is itself an event worth an alert, so that a forgotten suspension is visible.
- Proof, in `smoke.sh`: suspend `intern`; `intern` gets 403 on `fast` and cannot reach the gateway's port, while `research-agent` still completes a workflow; resume; `intern` gets 200 on `fast`.

## As built (2026-11-24)

- One script, `scripts/suspend.sh on|off <namespace>/<serviceaccount>` and `list`. It takes about a second.
- **Gateway:** an `AgentgatewayPolicy` named `suspended` on the whole Gateway, `action: Require` with `!(jwt.sub in [...])`, so an expression error denies. Verified live: it combines with each model's allow-list, so a suspended identity gets 403 even on a model it may use, while other identities are unaffected. The suspended identities are the policy's `adp.dev/suspended` annotation; `off` on the last one deletes the policy.
- **Network:** a `CiliumNetworkPolicy` `suspended-<sa>` in the identity's namespace, `egressDeny` to every entity, selected by `io.cilium.k8s.policy.serviceaccount`.
- **Workflow: not built.** The agent treats a gateway 403 as final (`agent/app.py:77`), so a run that calls the gateway while its identity is suspended fails, and its state stays in the store for review. Pausing first would keep such runs alive, but the cutoff would then wait on finding the identity's running instances, which Dapr 1.19 may not offer (unverified). Decided: the cutoff comes first.
- **Visible:** a suspended identity that keeps trying fires `GatewayCallerDenied` (any 403) and, from its pods, `EgressPolicyDrop` (ADR 0016). A suspension nobody trips raises nothing; `suspend.sh list` shows it.
- Proof, in `smoke.sh`: before, during and after suspending `intern`, from a pod running as `intern` and from the shared probe.
- The `mcp` listener is covered by the same Gateway-wide policy, but no smoke check exercises it (the tools stage is opt-in).
