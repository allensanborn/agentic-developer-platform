# 10. The agent reads through MCP tools behind the gateway; the executor writes through a binding

Status: accepted, 2026-11-12. The executor's binding is built. The agent's tools are not.

## Context

The model decides which read queries to run, so that is where per-tool policy and an audit trail matter. The executor has no model and runs fixed statements.

dapr-agents gives models database access through MCP servers. Neither dapr-agents nor Drasi shows a model-originated write.

## Decision

- The agent's read tools are an off-the-shelf PostgreSQL MCP server in read-only mode, using a read-only database role, reachable only through agentgateway with per-tool authorization.
- The executor writes through a Dapr PostgreSQL binding (ADR 0008).
- The gateway MCP wiring is timeboxed to half a day; the fallback is a read-only Dapr binding scoped to the agent.

## Alternatives considered

- **Both commit paths (binding and gateway MCP tool), compared.** Rejected: a model-facing protocol governs nothing extra for a writer with no model.
- **Dapr's sidecar `MCPServer` resource.** Needs a runtime with that support, unverified on 1.19.1, and bypasses the gateway.

## Consequences

- The database enforces the read/write split even if application code is wrong.
- Tool calls become visible and governable at the same place as model calls.
