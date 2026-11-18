# 5. Detect discrepancies deterministically; use the model to diagnose

Status: accepted, 2026-11-12. Detection rules as SQL views are built; the Drasi trigger is not built yet.

## Context

The ERP discrepancy agent has to find business data that breaks a rule and propose a repair. Letting a model write the detection query spends tokens on healthy data and makes recall a matter of chance. The stand-in ERP is the Chinook sample database on PostgreSQL.

## Decision

A detection rule is written down in advance and evaluated without a model. A discrepancy starts one run; the model's job is to diagnose it and propose a fix.

- Each rule is a view in the database's `detect` schema. The view is also the independent re-check after a fix.
- Runs are triggered by Drasi's standalone server (`drasi-server`), which watches PostgreSQL by logical replication. Its webhook posts to a Dapr sidecar on its own pod, which publishes to a topic the controller subscribes to.
- A run's identity is the rule, the row's key and an episode supplied by the trigger, so a duplicate delivery cannot start a second run.

## Alternatives considered

- **The model detects.** Rejected: non-deterministic recall and token cost on every change.
- **Drasi's Kubernetes platform.** Rejected: its latest release is a year-old pre-release that installs its own Dapr, Redis and MongoDB.
- **Polling the views on a schedule.** Simpler and enough for this data. Kept as the fallback if the Drasi server proves unreliable.
- **Drasi's `durable-task` reaction.** Starts workflows without a webhook, but targets Microsoft's Durable Task Scheduler; not verified against Dapr.

## Consequences

- Detection recall is 100% by construction, so evaluation measures fix selection (ADR 0011), not detection.
- Each rule exists twice: as a Drasi continuous query (Cypher) that triggers, and as a SQL view that checks. They can drift.
- Drasi announces a row once. A run that ends without a decision is not re-announced (ADR 0009 covers that).
- Drasi server's defaults keep state in memory; it needs a volume and persistence switched on, or changes made while it is down trigger nothing. Its REST API has no authentication, so NetworkPolicy must fence it.
