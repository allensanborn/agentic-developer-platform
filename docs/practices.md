# Where each practice comes from

The design follows practices recorded in the maintainer's notes and three earlier repositories. Status: **built** means implemented and verified here; **open** means tracked in beads.

## Gateway, credentials, routing

| Practice | Here | Source |
|---|---|---|
| Keep credentials out of the agent; inject them at the network boundary | built: the gateway attaches provider keys | maintainer notes; Radar vol. 35 entries for Omnigent, Varlock, Claude Managed Agents |
| Enforce at the network level so the broker cannot be bypassed | built: default-deny NetworkPolicy | maintainer notes ("you really do need both halves") |
| Treat the gateway as the highest-value credential target | built: no master key; keys resolved from Secrets Manager | maintainer notes |
| Attested, short-lived workload identity instead of shared keys | built: ServiceAccount tokens | maintainer notes |
| Do not default every task to a frontier model; route routine work to small models | built: `fast` drafts, `smart` reviews | maintainer notes |
| Put a gateway in front of local models | built | maintainer notes |
| Fail over on provider health | built: eviction on 5xx, 429, 401, 403 | maintainer notes |
| Keep gateway policy as reviewed config | built: everything is a manifest in `platform/gateway/` | maintainer notes |
| agentgateway for LLM, MCP and A2A traffic | built for LLM; MCP open | maintainer notes |
| Log request, decision and action; OpenTelemetry | open | maintainer notes |
| Token exchange with an `act` claim for on-behalf-of calls | open | maintainer notes |
| Per-tool authorization on MCP; discovered tools start disabled | open | maintainer notes |

## Agent runtime

| Practice | Here | Source |
|---|---|---|
| Run non-deterministic agents inside deterministic durable workflows | built: Dapr Workflow, model calls as activities | maintainer notes |
| The model never drives control flow | built: the workflow is fixed code | maintainer notes (Swamp) |
| Never return a credential through a workflow activity | built: the token is read inside the activity | maintainer notes |
| Agents simple, infrastructure sophisticated | built: the agent is about 70 lines with no credential or provider logic | maintainer notes |
| Sandbox every agent, sized to risk; seccomp RuntimeDefault as the cheapest control | built to Pod Security `restricted`; gVisor and Agent Sandbox open | maintainer notes |
| Threat-model GenAI systems; look for the lethal trifecta | built: `docs/threat-model.md`; no tool access yet, so no trifecta | maintainer notes |
| Evals as a CI gate | open | Radar vol. 35 (Promptfoo); maintainer notes |
| Layered guardrails, cheapest first, on high-stakes actions | open | maintainer notes |

## Platform

| Practice | Here | Source |
|---|---|---|
| Expose intent-level capabilities to agents, not raw infrastructure | partly: aliases are intent; a self-service "Agent" capability is open | maintainer notes |
| Put policy inside the capability | built: access and budget are in the gateway, not in agent code or prompts | same; maintainer notes |
| Pin tool versions; make the environment reproducible from zero | built: `versions.env`, digests, `devbox.lock`; `up.sh` from an empty cluster | maintainer notes |
| Guardrails should explain, not just refuse | open: denials are bare 401/403/429 | maintainer notes |

## From earlier repositories

| Taken | From |
|---|---|
| k3d over kind (enforced NetworkPolicy); alias-table routing; "every deny gets a control" in tests | `agentic-platform-local` |
| Its largest gap, closed here: the gateway held the key but authenticated no one | `agentic-platform-local` review |
| CI and laptop run the same Dagger functions; tool images by digest | `devbox-dagger-devcontainer` |
| Pinned toolchain in `devbox.json`; secrets read from a hidden prompt, never argv | `seeq-dapr-demo` |
| Avoided: hardcoded tokens, cluster-admin service accounts, unpinned charts | `back-stack/kubecon-na-2025` |

## Disagreements between sources

- **One central gateway, or a thin edge with authorization next to each agent?** maintainer notes argues the former; Fussell (maintainer notes) the latter. This repo keeps the gateway to keys, identity, access, budgets and failover, and leaves business rules to the agent runtime.
- **Egress injection or short-lived minted tokens as the primary credential model?** (maintainer notes.) Provider API keys cannot be minted per call, so injection is the only option for this hop.
- **kagent:** Radar says Trial; Farcic's review is negative. Not used; agents here are plain Deployments.
