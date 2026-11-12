# 9. Approval is a named person's decision on one exact proposal

Status: accepted, 2026-11-12. The binding, deadlines and outcomes are built. Keycloak and the gateway route are not: the approver is a header set by an operator script.

## Context

Dapr's workflow event API carries no authentication, and a proposal can be replaced by a retry while someone is reading it.

## Decision

- A decision names the run and the hash of the proposal it is for. The workflow ignores a decision whose hash is not the current proposal's, or that names no approver.
- The grant recorded in workflow history holds the approver, the hash, the tier and the time.
- People are identified by Keycloak. agentgateway verifies the token on a second route in front of the controller's decision endpoint; nothing else can reach that endpoint.
- Each approval tier has a deadline. When the first passes, the run escalates to a second tier. When that passes, the run ends as `unattended`. A deadline never approves.
- Outcomes: `committed`, `rejected`, `resolved_elsewhere`, `unattended`, `recommendation`.

## Consequences

- An approver cannot approve something other than what they saw.
- A rejected or unattended discrepancy is not retried automatically; Drasi does not announce it again.
- Until Keycloak is in place the approver name is unverified, which fails the "uniquely identified human" requirement.
- Later: RFC 8693 token exchange so the commit carries the approver as subject and the executor as actor.
