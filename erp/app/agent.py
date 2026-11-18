"""The agent: performs one diagnosis attempt when the controller asks.

It can read business data but never change it, and what it returns is only a proposal.
The attempt is one workflow activity, so it is the unit of durability: a finished attempt
is recorded and never repeated, an interrupted one starts over (ADR 0007).
"""

import signal

import dapr.ext.workflow as wf

import graph

runtime = wf.WorkflowRuntime()


@runtime.activity(name="diagnose")
def diagnose(ctx, req: dict) -> dict:
    return graph.diagnose(req["rule"], req["key"], req.get("rejected") or [])


if __name__ == "__main__":
    runtime.start()
    signal.pause()
