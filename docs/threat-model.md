# Threat model

Scope: the platform as built, on one cluster. Method: STRIDE over the trust boundaries, plus the agent-specific question of what a prompt-injected agent can do. "Verified" names the check that fails if the control breaks.

## Assets

1. Model provider API keys (money, and data sent to the provider).
2. The gateway's routing and access configuration.
3. Agent workflow state (prompts and model output, possibly sensitive).
4. Local model capacity.

## Trust boundaries

- **Agent pod to gateway.** The agent is untrusted: assume its prompt can be hijacked and its code can be made to send arbitrary requests.
- **Gateway to providers.** Leaves the cluster carrying a provider key.
- **Cluster to AWS** (floci locally). Holds the keys at rest.
- **Git to cluster.** Whoever can merge can change who is allowed what.

## Threats and controls

| # | Threat | Control | Verified |
|---|---|---|---|
| 1 | A compromised agent steals a provider key | The key is never in the agent's namespace, environment or filesystem; the gateway attaches it | smoke: key exists in one namespace |
| 2 | A workload calls the gateway as someone else | ServiceAccount token: signed, audience-bound, one hour | smoke: missing and wrong-audience tokens get 401 |
| 3 | An agent uses a model it should not (cost, data residency) | Allow-list per model; unlisted is denied | smoke: `intern` gets 403 on `smart` |
| 4 | An agent bypasses the gateway to reach a model or the internet (exfiltration) | Default-deny egress in `agents`; models accept only the gateway | smoke: three blocked paths |
| 5 | A workload in another namespace uses the gateway | Ingress only from labelled namespaces, then identity and allow-list | smoke: unlabelled namespace is blocked |
| 6 | A looping or hijacked agent runs up the bill | Token budget per identity | by hand: 429 at a 30-token budget |
| 7 | A stolen agent token is replayed | One-hour life; audience `ai-gateway` only; useless against the Kubernetes API | smoke: wrong audience rejected |
| 8 | A container escape or lateral move from an agent | Pod Security `restricted`, read-only root, no capabilities, no API token, seccomp | admission |
| 9 | A tampered dependency or image | Images by digest, Python by hash, charts and actions by version or SHA; scans in CI | `dagger call check` |
| 10 | A secret is committed | gitleaks over history and trivy over the tree in CI | `dagger call check` |
| 11 | Provider outage takes agents down | Failover to a local model | smoke: `smart` answers on fallback |
| 12 | A leaked provider key stays valid | Rotation is one command, live in about a minute | by hand: 45 s |

## Open risks

Each has a beads issue. None is mitigated today.

| Risk | Why it matters | Interim position |
|---|---|---|
| **Gateway listener is plain HTTP** | Bearer tokens and prompts cross the cluster network unencrypted; a node-level attacker can read and replay a token for up to an hour | Tokens are audience-bound and short-lived. Fix: TLS listener with cert-manager, or mesh mTLS |
| **No audit trail** | No record of who called which model with how many tokens; no tracing | agentgateway supports OTLP access logs and traces; not wired |
| **Prompt injection is unaddressed** | The controls here bound what a hijacked agent can reach and spend, not what it says or does with allowed tools | No tools are exposed yet. Before adding any: per-tool authorization at the gateway, and treat tool output as data |
| **No evaluation gate** | A model or prompt change behind an alias ships with no check that answers are still right | Aliases make the swap easy, which makes this more urgent |
| **Signing keys are a snapshot** | If the cluster rotates its ServiceAccount signing key, all callers fail until `up.sh` is re-run | Fails closed |
| **Rate-limit buckets are per replica** | Budgets multiply with gateway replicas | One replica today |
| **Dummy static AWS credentials** | Correct for floci only | Comments mark each place an IAM role replaces them |
| **Secrets in etcd** | The synced key is a Kubernetes Secret | Needs etcd encryption at rest on a real cluster |
| **Failover hides a rejected key** | A revoked provider key degrades to the local model with no alert | Needs the audit trail above |
| **Images are not signed; no SBOM** | Digest pinning stops substitution, not a bad build | Needs a registry, cosign and admission verification |
| **The Dapr sidecar shares the agent's network** | The agent container can reach the AWS endpoint the sidecar uses | On AWS the sidecar's role is scoped to one table |
| **The hosted path is untested with a real key** | Only the placeholder-key failover has run | Needs a key |
