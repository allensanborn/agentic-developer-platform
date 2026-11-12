# 8. A proposed fix is a typed operation, enforced by the database

Status: accepted, 2026-11-12. Built and covered by `scripts/erp-smoke.sh`.

## Context

If the model writes SQL, the executor runs text a model produced, the check has to parse it, and an approver is asked to approve a string. RFC 9396 grants need fields; Drasi's own write path binds parameters to fixed statements.

## Decision

Each detection rule declares its fix types in advance. A proposed fix is a fix type plus parameters and evidence. When no fix type fits, the model returns a written recommendation that goes to a person and can never be executed.

- Fix types are branches of the database function `fix.run()`.
- The executor's database role can execute `fix.dry_run()` and `fix.commit()` and nothing else: no tables, no `fix.run()`.
- `fix.dry_run()` applies the fix, re-checks the detection rule, and always rolls back.
- `fix.commit()` is one statement and so one transaction. It is idempotent on the proposal hash, does nothing if the discrepancy is already gone, and applies nothing if the fix no longer resolves it.
- The executor reaches the database through a Dapr binding loaded by its sidecar alone.

## Consequences

- The model cannot repair anything nobody anticipated. That limit is intended.
- Adding a fix type is a reviewed change to `erp/db/20-rules.sql` and `erp/app/rules.py`; the two can drift, and the database is the one that enforces.
- Every committed fix has a row in `fix.audit` naming the approver.
- The agent's read path (ADR 0010) is separate and read-only.
