# 15. Each Dapr sidecar serves only the APIs its app uses

Status: accepted, 2026-11-19. Built (bead adp-vba).

## Context

Cross-app access was already denied: `accessControl` defaults to deny, and a WorkflowAccessPolicy per ERP app names who may call which activity. But an app's **own** sidecar served every Dapr API to it: state, metadata, service invocation, secrets, pub/sub. A prompt-injected `erp-agent` could list every component through metadata, read and write state directly, or try invoking other apps, all through its own sidecar. Mandiant's Layer 1 (Nov 2026) asks for exactly these management paths to be closed. Its Layer 4 asks for the same of any capability a compromised workload doesn't need.

## Decision

- One Dapr `Configuration` per app (`agents`, `erp-controller`, `erp-agent`, `erp-executor`), each keeping `accessControl: deny` and adding `spec.api.allowed`.
- Allowed: HTTP `healthz` (the SDK's startup wait), plus gRPC `bindings` for the two apps whose binding is their read or write path. The other two get gRPC `shutdown`, which only lets an app stop its own sidecar.
- Workflow needs no entry. It runs on durabletask's gRPC service, which the allow-list does not filter (daprd v1.19.1 `pkg/api/grpc/endpoints.go` applies it only under `dapr.proto.runtime.v1.Dapr/`).

## The trap this ADR exists to record

The allow-list **fails open, silently**. daprd turns each gRPC rule's `name.version` into a set of methods, and a pair it doesn't know maps to nothing. If no rule maps to anything, the set is empty and the middleware passes every call through, while still logging "Enabled API access list on gRPC server". The Dapr docs list the Workflow API's gRPC version as `v1`. daprd 1.19.1 only has `workflows.v1alpha1` and `workflows.v1beta1`. The first version of this change allowed `workflows v1`, and gRPC `GetState` kept working. Hence the rule of one recognised gRPC rule per list, and a smoke check that calls `GetState` over raw gRPC and expects `UNIMPLEMENTED`. A mutation test with the `workflows v1` config makes that check fail.

## Consequences

- `smoke.sh`: research-agent's sidecar refuses state. `erp-smoke.sh`: erp-agent's sidecar answers its read binding and refuses state; the controller's sidecar refuses bindings. Both whole suites pass with the lists live.
- A new Dapr API use in app code fails at its first call with `UNIMPLEMENTED` until the app's Configuration allows it. That is the intended cost.
- A Dapr upgrade can rename API versions. The raw-gRPC smoke checks are what notice; the config validates either way.
