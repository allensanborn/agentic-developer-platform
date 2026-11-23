# 20. A run carries a scope, and the gateway enforces it

Status: proposed, 2026-11-23. Not built. The gateway features it relies on were read in agentgateway's source at tag `v1.7.0`; nothing was run.

## Context

Authorization is per identity. A ServiceAccount on the allow-list for `smart` and for `initiate_return` may use both in every run, for as long as its token lives, up to its token budget for the window. A hijacked run can therefore do anything its identity can, not only what that run was started for.

OpenAI's reference architecture for supervised investigations (2026-11-09) scopes each run: target, permitted actions, window and stopping point. The ERP tenant already has this shape by construction, because a run is one discrepancy and the fixes are typed (ADRs 0006, 0008). The sample agent and any future tenant do not.

What agentgateway v1.7.0 allows (source at the tag):

- `jwtAuthentication` takes one token location and a list of providers, so one token per request is verified, from any of several issuers (`JWTAuthentication`, `JWTProvider` in `agentgateway_policy_types.go`).
- Every claim of the verified token is visible to CEL as `jwt.*` (`schema/cel.md`). `request.headers` is visible too, but a header is not authenticated.
- A local rate limit's `key` is any CEL expression (`LocalRateLimit.Key`). The repo already uses `jwt.sub`.
- `exp` is checked whenever it is present.

## Decision (proposed)

- A **run scope** is four fields: the tools the run may call, the model aliases it may use, a token ceiling, and a deadline.
- Whoever starts the run declares the scope. For a controller-hosted workflow that is the controller, never the agent.
- The scope travels as **claims in a run token**: a short-lived JWT from a platform issuer, added as a second provider beside the cluster's. For that run the workload presents the run token in place of its ServiceAccount token. `sub` stays the workload's identity, so every existing allow-list keeps working. The deadline is `exp`.
- Policies add a scope clause that applies only when the claim is present, for example a tool call must satisfy the identity rule and `mcp.tool.name in jwt.tools`. A scope can narrow what an identity may do. It can never widen it.
- The run's token ceiling is a rate-limit rule keyed on the run id claim.
- A call with a plain ServiceAccount token is treated as today, so existing callers keep working until a tenant opts in.

## Alternatives considered

- **A scope token beside the ServiceAccount token.** The first draft of this ADR. The gateway verifies one token per request, so the second would be an unverified header.
- **A run id header as the rate-limit key.** Works today with no new component, and an agent that picks a fresh run id gets a fresh budget.
- **An external authorization service** that verifies a second token and returns its claims as `extauthz.*`. Possible, and it puts a new service on every call's path.
- **Enforce the scope in the agent's own code.** The agent is the untrusted party (threat model, trust boundaries).
- **One ServiceAccount per workflow type** (fallback). No new component: `order-status` and `ask` become separate identities with separate allow-lists. It narrows tools and aliases but gives no per-run ceiling or deadline. Take this if the token issuer is judged too much to own.

## Consequences

- A token issuer is a new component that holds a signing key and can name any `sub`. It must verify the caller's ServiceAccount token before it copies `sub`, and policies that trust scope claims must also pin `jwt.iss`. This is the same signing problem `adp-aty` has for approver grants, and ADR 0009 already lists RFC 8693 token exchange as a later step. Solve it once.
- The token ceiling is approximate. Token counts are known only after a response, so a limit applies to later requests. Each gateway replica keeps a bounded number of buckets and drops the least used, so a run's bucket can be evicted and start again. A window-based limit also refills in a run that outlives its unit.
- **Not verified:** how a scope clause combines with the existing allow-list expressions in one policy (the tag has `authorization-require` test data that suggests a require mode; it was not read), and how a route-level JWT policy merges with the gateway-level one.
- Proof: one smoke check where an identity allowed `initiate_return` is refused it inside a run scoped to `lookup_order`, beside the same call succeeding in a run scoped to both; and one where a run token past `exp` gets 401.
