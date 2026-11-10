# 2. Callers authenticate with their ServiceAccount token

Status: accepted, 2026-11-10

## Context

The gateway holds provider keys, so it must know who is calling. The usual answer, a "virtual key" per agent, creates a second set of long-lived secrets to distribute, rotate and leak.

## Decision

Agents present a projected Kubernetes ServiceAccount token with audience `ai-gateway`. The gateway validates signature, issuer and audience, and authorizes on the `sub` claim (`system:serviceaccount:<namespace>:<name>`).

## Consequences

- No caller secrets exist. The token lasts an hour, is rotated by the kubelet, and is useless against the Kubernetes API or any other audience.
- Clients must re-read the token file per request; `agent/app.py` does, and a unit test pins it.
- Tools that only accept a static API key cannot call the gateway directly. They need a sidecar that injects the token, or a separate key-authenticated listener. Not built.
- User identity is not carried. An agent acting for a person needs token exchange (RFC 8693) so its rights are the intersection of both. Not built.
