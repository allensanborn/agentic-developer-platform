# 10. The agent reads through MCP tools behind the gateway; the executor writes through a binding

Status: accepted, 2026-11-12. The executor's binding is built. The agent currently reads through the fallback (a read-only Dapr binding); gateway MCP tools are bead adp-2id.

## Context

The model decides which read queries to run, so that is where per-tool policy and an audit trail matter. The executor has no model and runs fixed statements.

dapr-agents gives models database access through MCP servers. Neither dapr-agents nor Drasi shows a model-originated write.

## Decision

- The agent's read tools are an off-the-shelf PostgreSQL MCP server in read-only mode, using a read-only database role, reachable only through agentgateway with per-tool authorization.
- The executor writes through a Dapr PostgreSQL binding (ADR 0008).
- The gateway MCP wiring is timeboxed to half a day; the fallback is a read-only Dapr binding scoped to the agent.

## Why the fallback was taken

- The off-the-shelf server tried (`crystaldba/postgres-mcp`) is a 440 MB image last built in May 2025, runs as root by default and offers only the SSE transport. That is a poor thing to put in front of a database under this repository's rules.
- The diagnosis graph gathers a fixed set of facts per rule in code; the model does not choose queries yet. Per-tool policy would govern nothing until it does.
- The agentgateway side is straightforward: an `AgentgatewayBackend` with an `mcp` target, an `HTTPRoute`, and a policy matching on `mcp.tool.name` and `jwt.sub`.

## Alternatives considered

- **Both commit paths (binding and gateway MCP tool), compared.** Rejected: a model-facing protocol governs nothing extra for a writer with no model.
- **Dapr's sidecar `MCPServer` resource.** Needs a runtime with that support, unverified on 1.19.1, and bypasses the gateway.

## Consequences

- The database enforces the read/write split even if application code is wrong.
- Tool calls become visible and governable at the same place as model calls.
