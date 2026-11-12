# 7. LangGraph runs inside one activity; no Diagrid package, no checkpointer

Status: accepted, 2026-11-12. The diagnosis graph is not built yet; the agent is a stub.

## Context

Diagrid's guidance for LangGraph is `DaprWorkflowGraphRunner`, which turns each graph node into a Dapr Workflow activity so a crash resumes at the interrupted node. A spike on this cluster confirmed it works as a child workflow of a hand-written workflow.

Two findings decided against it:

- The `diagrid` Python package is under the Business Source License 1.1. Its terms prohibit using it to power agent runtime infrastructure or managed agent platforms, including internally. That describes this repository.
- Using it as a child workflow needs three private attributes of the runner.

The diagnosis graph is read-only and a handful of model calls, so there is no side effect for node-level recovery to protect.

## Decision

Each diagnosis attempt is one ordinary Dapr Workflow activity that runs a plain LangGraph graph. Dapr is the only durability layer: a finished attempt is recorded and never repeated, an interrupted one starts over.

## Consequences

- Only Apache-2.0 components from the Dapr project are used.
- A crash mid-attempt repeats a few read queries and model calls.
- If a graph grows long or expensive, `dapr-ext-langgraph` (Apache 2.0) stores LangGraph checkpoints in a Dapr state store, so a retried activity could resume mid-graph. Not needed now.
- Human approval lives in the workflow, not in LangGraph's `interrupt()`.
