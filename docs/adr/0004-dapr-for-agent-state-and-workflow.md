# 4. Dapr for durable workflow and backing services

Status: accepted, 2026-11-10

## Context

Agent runs are long, call non-deterministic models, and fail midway. Their state store should be replaceable without touching agent code.

## Decision

Agents run a deterministic Dapr Workflow whose activities make the model calls. State goes through Dapr's state API to a component; here DynamoDB (on floci). Dapr is not used for model access: that path goes to the gateway so that identity, access and budget are enforced in one place.

## Consequences

- A crash resumes from recorded activity results instead of asking the model again and getting a different answer. The workflow history is an audit record.
- Changing the state backend is a change to `platform/dapr/agents.yaml`.
- Activities must not return credentials: results are persisted and replayed. The agent reads its token inside the activity, per call.
- The sidecar runs with no Kubernetes API token and the built-in secret store disabled; mTLS and SPIFFE identities between sidecars come from Dapr Sentry by default.
- Dapr's control plane (operator, sentry, placement, three scheduler replicas, injector) is the largest footprint on the cluster.
