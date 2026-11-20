# Threat model

Scope: the platform as built, on one cluster. Method: STRIDE over the trust boundaries, plus the agent-specific question of what a prompt-injected agent can do. "Verified" names the check that fails if the control breaks.

## Assets

1. Model provider API keys (money, and data sent to the provider).
2. The gateway's routing and access configuration.
3. Agent workflow state (prompts and model output, possibly sensitive).
4. Local model capacity.
5. ERP data, and the right to change it (an approved fix commits to the database).
6. Developer machines and their credentials: coding agents run this repository's harness there.

## Trust boundaries

- **Agent pod to gateway.** The agent is untrusted: assume its prompt can be hijacked and its code can be made to send arbitrary requests.
- **Gateway to providers.** Leaves the cluster carrying a provider key.
- **Cluster to AWS** (floci locally). Holds the keys at rest.
- **Git to cluster.** Whoever can merge can change who is allowed what.
- **Gateway to tools.** MCP calls to tool servers (orders, code execution), made under the caller's identity; tool output comes back as untrusted text.
- **Broker to sandbox.** Model-written code runs in a gVisor sandbox claimed from a warm pool, with no network.
- **Repository to developer machine.** Coding agents execute repository config (hooks, MCP servers, instructions) when a developer opens the repo.

## Threats and controls

| # | Threat | Control | Verified |
|---|---|---|---|
| 1 | A compromised agent steals a provider key | The key is never in the agent's namespace, environment or filesystem; the gateway attaches it | smoke: key exists in one namespace; `boundary_register.yaml`: `provider-key-not-in-agents` |
| 2 | A workload calls the gateway as someone else | ServiceAccount token: signed, audience-bound, one hour | smoke: missing and wrong-audience tokens get 401; `boundary_register.yaml`: `gateway-audience` |
| 3 | An agent uses a model it should not (cost, data residency) | Allow-list per model; unlisted is denied | smoke: `intern` gets 403 on `smart`; `boundary_register.yaml`: `principal-*`, `alias-*` |
| 4 | An agent bypasses the gateway to reach a model or the internet (exfiltration) | Default-deny egress in `agents`; models accept only the gateway | smoke: three blocked paths |
| 5 | A workload in another namespace uses the gateway | Ingress only from labelled namespaces, then identity and allow-list | smoke: unlabelled namespace is blocked; `boundary_register.yaml`: `gateway-client-label` |
| 6 | A looping or hijacked agent runs up the bill | Token budget per identity; `GatewayTokenVelocity` alert per caller (ADR 0016) | by hand: 429 at a 30-token budget; `dagger call check`: `Alerts` |
| 7 | A stolen agent token is replayed | One-hour life; audience `ai-gateway` only; useless against the Kubernetes API | smoke: wrong audience rejected; `boundary_register.yaml`: `gateway-audience` |
| 8 | A container escape or lateral move from an agent | Pod Security `restricted`, read-only root, no capabilities, no API token, seccomp | admission |
| 9 | A tampered dependency or image | Images by digest, Python by hash, charts and actions by version or SHA; scans in CI | `dagger call check` |
| 10 | A secret is committed | gitleaks over history and trivy over the tree in CI | `dagger call check` |
| 11 | Provider outage takes agents down | Failover to a local model | smoke: `smart` answers on fallback |
| 12 | A leaked provider key stays valid | Rotation is one command, live in about a minute | by hand: 45 s |
| 13 | A known-vulnerable pinned version stays deployed (n-day window measured in days) | Renovate bumps every pin; known-vulnerable versions skip the release-age wait and the schedule (ADR 0012) | `dagger call check`: `RenovateConfig`; `dagger call renovate` reports pending bumps |
| 14 | A poisoned agent harness (`.claude/settings.json` hook, `.mcp.json` server, agent instructions) runs code on every developer who opens the repo | `harness.lock` content lock; `devbox.json` may not declare `init_hook` (ADR 0013). Advisory: no branch protection on this plan | `dagger call check`: `Harness` |
| 15 | A leaked gateway credential is used or resold, or an attacker churns new identities to dodge per-identity budgets (LLMJacking, "burn and rotate", GTIG Nov 2026) | Authorization names each ServiceAccount (`jwt.sub`), so a new identity has no rights; no caller keys exist to escalate (ADR 0002) | smoke: `intern` gets 403 on `smart`; `GatewayCallerDenied` |
| 16 | The gateway, which holds the provider key, sends data to attacker infrastructure (webhook services, LLM resale proxies) | Cilium FQDN fence: `openrouter.ai:443` and nothing else on the internet (ADR 0014) | smoke: the gateway reaches its provider by name; other services and raw IPs are blocked |
| 17 | A compromised app uses its own Dapr sidecar to read state, list components or call other apps | Per-app API allow-lists; each holds a rule daprd recognises, since an unknown one fails open (ADR 0015) | smoke, erp-smoke: raw gRPC `GetState` is `UNIMPLEMENTED`; the agent's read binding still answers |
| 18 | Machine-speed probing or spending by a valid identity goes unnoticed | Alerts per caller (token velocity, refusal bursts, any 403) and on policy-denied drops (ADR 0016) | `dagger call check`: `Alerts` (promtool); smoke: a refusal burst and a blocked egress each fire their alert |
| 19 | Text in tool output steers a model into acting (prompt injection) | Per-tool authorization at the gateway; tool output reaches a model step with no tools, framed as data; a prompt-guard tripwire refuses known phrasings | tools-smoke: an injected record reaches the agent as tool output, the guard refuses the model call; `intern` cannot see or call tools it is not granted |
| 20 | Model-written code escapes its sandbox or exfiltrates | gVisor runtime with enforced seccomp; no network and no Kubernetes API from a claimed sandbox; `run_python` granted to `research-agent` only | sandbox-smoke: own kernel, seccomp enforced, no internet, no API (each beside a control that has them) |
| 21 | A backend's error text tells a caller which server or provider sits behind an alias, and feeds an agent's trial-and-error | Backend 5xx, and JSON 401/403/429, get a fixed body; the gateway's own decisions pass through (`platform/gateway/errors.yaml`) | smoke: a backend error carries no detail; the prompt guard's refusal still says why |

## Open risks

Each has a beads issue. None is fully mitigated today.

| Risk | Why it matters | Interim position |
|---|---|---|
| **Gateway listener is plain HTTP** | Bearer tokens and prompts cross the cluster network unencrypted; a node-level attacker can read and replay a token for up to an hour | Tokens are audience-bound and short-lived. Fix: TLS listener with cert-manager, or mesh mTLS |
| **Telemetry is in memory, and nobody is paged** | Traces (Jaeger) and metrics (Prometheus) do not survive a pod restart; alerts fire but reach no one | Firing alerts are read from the Prometheus API; Alertmanager and durable storage are the next step (ADR 0016) |
| **Prompt injection is contained, not prevented** | The guard catches only the phrasings it lists; the structural defense (tool output to a tool-less step) holds only where an agent is written that way | Threat 19. A new tool with side effects needs the same framing and its own authorization before any agent gets it |
| **No evaluation gate** | A model or prompt change behind an alias ships with no check that answers are still right | Aliases make the swap easy, which makes this more urgent |
| **Signing keys are a snapshot** | If the cluster rotates its ServiceAccount signing key, all callers fail until `up.sh` is re-run | Fails closed |
| **Rate-limit buckets are per replica** | Budgets multiply with gateway replicas | One replica today |
| **Dummy static AWS credentials** | Correct for floci only | Comments mark each place an IAM role replaces them |
| **Secrets in etcd** | The synced key is a Kubernetes Secret | Needs etcd encryption at rest on a real cluster |
| **Failover hides a rejected key, and fails the first calls after an endpoint dies** | A revoked provider key degrades to the local model with no alert; failover is per-request eviction, so the call that finds a dead backend gets its error | The agents retry (workflow activities with a RetryPolicy), and the retry falls through. Gateway-side `traffic.retry` re-sends to the same backend on agentgateway v1.7.0, so it cannot help (`adp-alr`). The hosted 401 is in traces, not a metric |
| **Images are not signed; no SBOM** | Digest pinning stops substitution, not a bad build | Needs a registry, cosign and admission verification |
| **The Dapr sidecar shares the agent's network** | The agent container can reach the AWS endpoint the sidecar uses | On AWS the sidecar's role is scoped to one table |
| **The hosted path is untested with a real key** | Only the placeholder-key failover has run | Needs a key |
| **CI is advisory** | Branch protection is not available on this repository's plan, so `dagger call check` (including the harness lock, ADR 0013) can be pushed past | Every change lands through a PR; revisit if the plan changes |
