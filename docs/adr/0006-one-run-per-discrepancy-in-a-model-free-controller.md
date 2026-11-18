# 6. One durable run per discrepancy, hosted by a controller with no model

Status: accepted, 2026-11-12. Built and covered by `scripts/erp-smoke.sh`.

## Context

A run asks for a diagnosis, checks the proposed fix, waits for a person, then commits. The wait can last days. Whichever workload hosts the workflow controls its data, including the record that a person approved: Dapr always lets an app act on its own workflows, and calls between apps are open until a `WorkflowAccessPolicy` closes them.

## Decision

A run is one Dapr Workflow instance, hosted by a separate controller. Three workloads, each with its own identity:

- **Controller** runs the workflow. No model, no database access.
- **Agent** performs diagnosis attempts when asked. Has a model; can change nothing.
- **Executor** checks and commits fixes. Holds the only write access; no model.

`WorkflowAccessPolicy` resources allow the controller to call `diagnose` on the agent and `dry_run`/`commit` on the executor, and allow nothing else. Callers are identified by their Sentry-issued mTLS identity.

## Alternatives considered

- **Controller and executor merged.** One fewer deployment, but the process that parses model output would hold the write credential.
- **Workflow inside the agent, executor verifies a signed grant.** A hijacked agent could start runs and raise its own approval event; safety would rest entirely on a signing scheme that is not designed.
- **Two workflows joined by a stored proposal.** Breaks the rule that intent, decision and effect share one run identity.

## Consequences

- A hijacked agent can only return a bad proposal. The smoke test replaces the agent's code with a direct call to `commit` and the executor's sidecar refuses it; weakening the policy lets the same attack through, so the test exercises the policy.
- The executor trusts the controller's word about who approved. A compromised controller could commit a declared fix type without a person. Hardening: the executor verifies the approver's signed grant, or the policy's `requires` rule (needs history signing, a preview feature).
- All three apps must share a namespace and a workflow state store. History is stored unencrypted in that store.
- The approach follows the AAIF reference patterns: proposal/execution split, human approval gate, durable wait, deterministic acceptance gate, bounded convergence loop.
