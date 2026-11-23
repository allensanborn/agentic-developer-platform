# 23. Evidence comes from the gateway's record, not the agent's report

Status: proposed, 2026-11-23. Not built.

## Context

An approver (ADR 0009) decides on a proposal the agent wrote, with facts the agent gathered. The gateway independently records every model and tool call with the caller, the tool and the trace id (ADR 0017), and `smoke.sh` already proves that every gateway call nests under an agent span. Nothing compares the two in the other direction, and nothing shows the approver the independent record.

That record also lives on one pod's volume with the image's default retention for logs and traces (`platform/telemetry/lgtm.yaml` sets retention for Prometheus only). The threat model lists this as an open risk.

OpenAI's reference architecture for supervised investigations (2026-11-09) ends every run by matching the agent's own request table against the target's access log by time, path and status, and keeps both in a store the agent's account cannot change or delete.

## Decision (proposed)

- **Reconcile before approval.** When a diagnosis returns, the controller reads the gateway's access log for that run's trace id and compares it with the tool calls the agent's proposal cites. A cited call the gateway never saw, or a gateway call the proposal omits, marks the proposal `unreconciled` and it is not offered for approval.
- **Show the approver the gateway's list**, not the agent's summary of it.
- **Keep the record past the pod.** The gateway access log is also written to an object-storage bucket with a retention lock, by a role that can append and cannot delete. Locally that is floci's S3.

## Alternatives considered

- **Trust the agent's tool list because Dapr records activities.** Workflow history is written by the workload being checked.
- **Sign each tool result at the tool server.** Stronger, and it needs every tool server changed. The gateway already sits on every call.

## Consequences

- The controller gains read access to one query endpoint. Today nothing in the cluster can reach the query ports (README, Run it), so this is a deliberate, narrow exception with its own network policy and its own deny check.
- A lagging log pipeline delays approvals. The reconcile step needs a bounded wait and then fails closed.
- **Unverified:** whether floci emulates S3 Object Lock. If it does not, the local proof is the append-only role (a delete is refused), and the retention lock is checked only against real AWS.
- Proof, in `erp-smoke.sh`: a scripted diagnosis that cites a tool call it never made ends `unreconciled` and no approval can commit it, beside an honest diagnosis that reconciles.
