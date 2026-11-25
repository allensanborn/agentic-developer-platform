# 25. Callers prove identity with SPIRE SVIDs over mTLS; WireGuard encrypts between nodes

Status: proposed, 2026-11-25. Spiked on a second cluster (`adp-spire`); not built into the platform. Supersedes ADR 0002 when built, and closes the plain-HTTP open risk in the threat model.

## Context

Callers send a projected ServiceAccount token as a bearer token to the gateway over plain HTTP (ADR 0002). Anyone who can read that hop gets every prompt and response, and a token that replays at the gateway for up to 10 minutes. Dapr's mTLS covers only sidecar-to-sidecar hops, and the agents call the gateway directly, not through a sidecar. Dapr's Sentry issues SVIDs to sidecars, not to apps.

The options weighed were TLS on the listeners with a local CA, Cilium WireGuard alone, a Dapr sidecar on the gateway, and SPIRE plus WireGuard. Chosen for the spike: SPIRE plus WireGuard, because a certificate whose key never leaves the pod can't be replayed from a sniffed connection, and the same handshake encrypts the hop.

## What the spike showed (2026-11-25, k3d on OrbStack, two nodes)

- **WireGuard works on k3d under OrbStack.** Cilium 1.20.4 with `encryption: {enabled: true, type: wireguard}` brought up `cilium_wg0` on both nodes, each with one peer.
- **WireGuard does not cover same-node traffic**, as Cilium documents. Five HTTP requests between pods on one node added 0 bytes to `cilium_wg0`'s transmit counter. Five across nodes added about 8 KB. So WireGuard alone leaves agent → gateway in plain text whenever the scheduler puts both on one node.
- **SPIRE runs at Pod Security `restricted`.** The hardened charts (`spire` 0.31.0, SPIRE 1.16.0; `spire-crds` 0.6.1) issue `spiffe://adp.local/ns/<namespace>/sa/<serviceaccount>` to every pod outside SPIRE's own namespaces. A pod in a `restricted` namespace got its SVID through the CSI volume (`csi.spiffe.io`) in about 0.5 s. The IDs map one-to-one onto today's `jwt.sub` (`system:serviceaccount:<ns>:<sa>`).
- **agentgateway v1.7.0 is a SPIFFE workload.** `AgentgatewayParameters.spec.spiffe: {}` mounts the Workload API socket, and the listener option `agentgateway.dev/tls-certificate-source: SPIFFE` terminates TLS with the gateway's own SVID (`spiffe://adp.local/ns/spike-gw/sa/spike-gw`). On that listener, client SVIDs are always required.
- **Authorization on the proven identity works.** With `source.spiffeId == "spiffe://adp.local/ns/agents/sa/research-agent"`:

  | Caller | Result |
  |---|---|
  | `research-agent` with its SVID | 200 |
  | `intern` with its SVID | 403 |
  | No client certificate | handshake refused (`certificate required`) |
  | Plain HTTP to the port | fails |

- **Clients need no new library.** Python's `ssl` plus `urllib` (what the agents use) loads the SVID and verifies the gateway against the SPIRE bundle. Hostname checking is off, since SVIDs carry a SPIFFE URI rather than a DNS name, and the client can check the gateway's SPIFFE ID from the peer certificate instead.
- **Cost:** about 180 MiB across two nodes (server 65, agent about 28 per node, CSI driver about 23 per node, OIDC discovery provider 14, which isn't needed). SVIDs live 4 hours.

## Decision (proposed)

- SPIRE issues every workload an SVID. The gateway's `llm` and `mcp` listeners become SPIFFE mTLS, and every `jwt.sub == ...` rule becomes `source.spiffeId == "spiffe://<td>/ns/<ns>/sa/<sa>"`. That covers the per-model allow-lists, the tool rules, `suspend.sh`'s Require rule, the token budget key, and the alerts' `caller` label.
- Cilium WireGuard stays on for every node-to-node hop: gateway → models, agents → Postgres, telemetry.
- Projected ServiceAccount tokens and the JWKS snapshot (`up.sh`, `adp-k1y`) are removed from the caller path.

## Open before building

- **Rotation.** The spike fetched one SVID in an init container, and that SVID expires after 4 hours. Apps need a refreshed copy: a `spiffe-helper` native sidecar writing the files, which the apps re-read on every call as they do the token today, or the Workload API from the app. Neither was tried.
- **Gateway outbound mTLS** (`backendTLS` SPIFFE) to MCP servers and the sandbox broker. Not tried; Ollama has no TLS, so those hops rely on WireGuard and then only cross-node.
- **Metrics and logs keyed on `jwt.sub`** (rate limit, `caller` label, alerts, dashboard) need the SPIFFE ID instead. Untested: whether the rate limit can key on `source.spiffeId`.
- **The fence probe and smoke scripts** call the gateway with `kubectl create token`. They'll need SVIDs, which means probe pods with the CSI volume.
- **Dapr Sentry** keeps its own trust domain. Putting it under SPIRE's root, so there is one trust domain, was not tried.

## Consequences

- **We give up** a platform without an identity control plane, **to get** callers whose credential can't be replayed, and an encrypted agent → gateway hop wherever the pods land.
- One more system to run (SPIRE server and agents), and an outage of its server stops new SVIDs. Existing ones last 4 hours.
- A node-level attacker can no longer read prompts or replay a credential on that hop.
