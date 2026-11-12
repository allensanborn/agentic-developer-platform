"""The executor: the only workload that can change business data, and it contains no model.

It exposes two activities. Both call a database function through a Dapr binding whose
database role can execute those two functions and nothing else.
"""

import json
import os
import signal

import dapr.ext.workflow as wf
from dapr.clients import DaprClient

BINDING = os.environ.get("WRITE_BINDING", "erp-write")

runtime = wf.WorkflowRuntime()


def call(sql: str, params: list) -> dict:
    with DaprClient() as d:
        resp = d.invoke_binding(BINDING, "query", binding_metadata={"sql": sql, "params": json.dumps(params)})
    value = json.loads(resp.data)[0][0]  # one row, one jsonb column
    return json.loads(value) if isinstance(value, str) else value


@runtime.activity(name="dry_run")
def dry_run(ctx, p: dict) -> dict:
    return call("SELECT fix.dry_run($1, $2, $3, $4::jsonb)", [p["rule"], p["key"], p["fix_type"], json.dumps(p["params"])])


@runtime.activity(name="commit")
def commit(ctx, p: dict) -> dict:
    return call(
        "SELECT fix.commit($1, $2, $3, $4::jsonb, $5, $6)",
        [p["rule"], p["key"], p["fix_type"], json.dumps(p["params"]), p["hash"], p["approver"]],
    )


if __name__ == "__main__":
    runtime.start()
    signal.pause()
