"""The agent: performs one diagnosis attempt when the controller asks.

It can read business data but never change it, and what it returns is only a proposal.
"""

import signal

import dapr.ext.workflow as wf

runtime = wf.WorkflowRuntime()


@runtime.activity(name="diagnose")
def diagnose(ctx, req: dict) -> dict:
    # ponytail: stub until the LangGraph diagnosis lands; always proposes the first fix type.
    return {"kind": "fix", "fix_type": "set_invoice_total_from_lines", "params": {}, "evidence": "stub: no model consulted"}


if __name__ == "__main__":
    runtime.start()
    signal.pause()
