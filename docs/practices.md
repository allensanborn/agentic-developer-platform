# Where each practice comes from

The design follows practices from the sources below and from three earlier repositories. A source written as "notes: topic" is the maintainer's own reading notes on that topic, which are not published. Status: **built** means implemented and verified here; **open** means tracked in beads.

## Gateway, credentials, routing

| Practice | Here | Source |
|---|---|---|
| Keep credentials out of the agent; inject them at the network boundary | built: the gateway attaches provider keys | notes: credential brokering; Radar vol. 35 entries for Omnigent, Varlock, Claude Managed Agents |
| Enforce at the network level so the broker cannot be bypassed | built: default-deny NetworkPolicy | notes: credential brokering ("you really do need both halves") |
| Treat the gateway as the highest-value credential target | built: no master key; keys resolved from Secrets Manager | notes: LLM gateway, [LiteLLM](https://github.com/BerriAI/litellm) |
| Attested, short-lived workload identity instead of shared keys | built: ServiceAccount tokens | notes: SPIFFE and SPIRE, notes: secretless agent access |
| Do not default every task to a frontier model; route routine work to small models | built: `fast` drafts, `smart` reviews | [Thoughtworks Radar: blanket frontier model usage](https://www.thoughtworks.com/radar/techniques/blanket-frontier-model-usage), [Thoughtworks Radar: small language models](https://www.thoughtworks.com/radar/techniques/small-language-models) |
| Put a gateway in front of local models | built | notes: LLM gateway |
| Fail over on provider health | built: eviction on 5xx, 429, 401, 403 | notes: LLM model routing |
| Keep gateway policy as reviewed config | built: everything is a manifest in `platform/gateway/` | notes: AI gateway |
| agentgateway for LLM, MCP and A2A traffic | built for LLM and MCP (`tools/`, opt-in); A2A not used | [Thoughtworks Radar: agentgateway](https://www.thoughtworks.com/radar/platforms/agentgateway) |
| Log request, decision and action; OpenTelemetry | built: a span per model and tool call, access log in Loki (ADR 0017) | notes: AI gateway, [Thoughtworks Radar: OpenTelemetry](https://www.thoughtworks.com/radar/languages-and-frameworks/opentelemetry) |
| Token exchange with an `act` claim for on-behalf-of calls | open | [Diagrid: on-behalf-of delegation](https://www.diagrid.io/blog/agent-identity-on-behalf-of-delegation) |
| Per-tool authorization on MCP; discovered tools start disabled | built: one policy per tool; a tool with no rule is absent from `tools/list` | notes: MCP gateway |

## Agent runtime

| Practice | Here | Source |
|---|---|---|
| Run non-deterministic agents inside deterministic durable workflows | built: Dapr Workflow, model calls as activities | notes: durable execution |
| The model never drives control flow | built: the workflow is fixed code | notes: behavior-centric AI design (Swamp) |
| Never return a credential through a workflow activity | built: the token is read inside the activity | notes: typed grants in a durable workflow |
| Agents simple, infrastructure sophisticated | built: the agent is about 70 lines with no credential or provider logic | [Why Dapr Agents](https://docs.dapr.io/developing-ai/dapr-agents/dapr-agents-why/) |
| Sandbox every agent, sized to risk; seccomp RuntimeDefault as the cheapest control | built to Pod Security `restricted`; gVisor and agent-sandbox for model-written code (`sandbox/`, opt-in) | notes: agent sandboxing, [Thoughtworks Radar: agent sandboxing](https://www.thoughtworks.com/radar/techniques/agent-sandboxing) |
| Threat-model GenAI systems; look for the lethal trifecta | built: `docs/threat-model.md`; tool output reaches a model step that has no tools (threat 19) | [Thoughtworks Radar: threat modeling](https://www.thoughtworks.com/radar/techniques/threat-modeling), [Thoughtworks Radar: toxic flow analysis for AI](https://www.thoughtworks.com/radar/techniques/toxic-flow-analysis-for-ai) |
| Evals as a CI gate | open | Radar vol. 35 (Promptfoo); [akuity/agent-delivery-demo](https://github.com/akuity/agent-delivery-demo) |
| Layered guardrails, cheapest first, on high-stakes actions | partly: a gateway prompt guard; an output-side check is open | notes: agent guardrails |

## Platform

| Practice | Here | Source |
|---|---|---|
| Expose intent-level capabilities to agents, not raw infrastructure | partly: aliases are intent; a self-service "Agent" capability is open | "Platform Engineering after the AI Hype" (KubeCon NA 2026 talk), notes: the agent as a platform consumer |
| Put policy inside the capability | built: access and budget are in the gateway, not in agent code or prompts | same; notes: agent guardrails |
| Pin tool versions; make the environment reproducible from zero | built: `versions.env`, digests, `devbox.lock`; `up.sh` from an empty cluster | [Why Infrastructure Platforms Must Be Reproducible](https://hackernoon.com/why-infrastructure-platforms-must-be-reproducible) |
| Pinning is not patching: bump every pin automatically, fast-track known-vulnerable versions | built: `dagger call renovate` (ADR 0012); App not yet created | [GTIG AI Threat Tracker, Nov 2026](https://cloud.google.com/blog/topics/threat-intelligence/agentic-threat-activity-crosses-a-significant-threshold), notes: this repo against Mandiant's five layers |
| Treat agent-harness config as executable code | built: `harness.lock` checked in `dagger call check` (ADR 0013) | notes: agent-harness config poisoning, [GTIG AI Threat Tracker, Nov 2026](https://cloud.google.com/blog/topics/threat-intelligence/agentic-threat-activity-crosses-a-significant-threshold) |
| Guardrails should explain, not just refuse | open: denials are bare 401/403/429 | notes: lane assist |

## From earlier repositories

| Taken | From |
|---|---|
| k3d over kind (enforced NetworkPolicy); alias-table routing; "every deny gets a control" in tests | `agentic-platform-local` |
| Its largest gap, closed here: the gateway held the key but authenticated no one | `agentic-platform-local` review |
| CI and laptop run the same Dagger functions; tool images by digest | `devbox-dagger-devcontainer` |
| Pinned toolchain in `devbox.json`; secrets read from a hidden prompt, never argv | `seeq-dapr-demo` |
| Avoided: hardcoded tokens, cluster-admin service accounts, unpinned charts | `back-stack/kubecon-na-2025` |

## Disagreements between sources

- **One central gateway, or a thin edge with authorization next to each agent?** notes: AI gateway argues the former; Fussell ([The Agent Industry Is Rebuilding SOA, Mistakes Included](https://medium.com/@mark.fussell/the-agent-industry-is-rebuilding-soa-mistakes-included-3988d032cf39)) the latter. This repo keeps the gateway to keys, identity, access, budgets and failover, and leaves business rules to the agent runtime.
- **Egress injection or short-lived minted tokens as the primary credential model?** (notes: credential brokering.) Provider API keys cannot be minted per call, so injection is the only option for this hop.
- **kagent:** Radar says Trial; Farcic's review is negative. Not used; agents here are plain Deployments.
