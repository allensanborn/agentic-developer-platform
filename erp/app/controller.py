"""The controller: carries each run from detection to its outcome.

It contains no model and holds no database credential. It asks the agent for a proposed
fix, has the executor check it, parks until an approver decides, and only then asks the
executor to commit. The run is one Dapr Workflow instance, so its history is the record of
who proposed, who approved and what was applied.
"""

import hashlib
import json
import os
import signal
import threading
from datetime import timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import dapr.ext.workflow as wf

from rules import RULES

AGENT_APP = os.environ.get("AGENT_APP_ID", "erp-agent")
EXECUTOR_APP = os.environ.get("EXECUTOR_APP_ID", "erp-executor")
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "2"))
# Each approval tier gets this long. Passing a deadline never approves anything.
APPROVAL_SECONDS = int(os.environ.get("APPROVAL_SECONDS", "86400"))
TIERS = ("approvers", "escalation")

RETRY = wf.RetryPolicy(first_retry_interval=timedelta(seconds=2), max_number_of_attempts=3, backoff_coefficient=2)

runtime = wf.WorkflowRuntime()


def proposal_hash(proposal: dict) -> str:
    """Identity of one exact proposed fix in one run; a grant is bound to it.

    The run is part of it: the same fix proposed for a discrepancy that recurs later is a
    new proposal, or the executor would treat its commit as a replay of the old one.
    """
    core = {k: proposal[k] for k in ("run", "rule", "key", "fix_type", "params")}
    return hashlib.sha256(json.dumps(core, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def handle_discrepancy(ctx: wf.DaprWorkflowContext, inp: dict):
    rule, key = inp["rule"], inp["key"]
    declared = RULES[rule]["fix_types"]

    # Bounded attempts: the agent proposes, a deterministic check decides.
    proposal, rejected = None, []
    for attempt in range(1, MAX_ATTEMPTS + 1):
        d = yield ctx.call_activity(
            "diagnose", input={"rule": rule, "key": key, "attempt": attempt, "rejected": rejected},
            app_id=AGENT_APP, retry_policy=RETRY,
        )
        if d.get("kind") != "fix":
            return {"outcome": "recommendation", "text": d.get("text", ""), "rejected": rejected}
        fix = {"fix_type": d.get("fix_type"), "params": d.get("params") or {}}
        if fix["fix_type"] not in declared:
            rejected.append({**fix, "error": "fix type is not declared for this rule"})
            continue
        check = yield ctx.call_activity(
            "dry_run", input={"rule": rule, "key": key, **fix}, app_id=EXECUTOR_APP, retry_policy=RETRY
        )
        if check.get("resolves"):
            proposal = {"run": ctx.instance_id, "rule": rule, "key": key, **fix,
                        "evidence": d.get("evidence", ""), "model": d.get("model"), "attempt": attempt}
            break
        rejected.append({**fix, "error": check.get("error") or "does not resolve the discrepancy"})
    if proposal is None:
        return {"outcome": "recommendation", "text": "no proposed fix passed the check", "rejected": rejected}

    h = proposal_hash(proposal)
    resolved = ctx.wait_for_external_event("resolved")  # the discrepancy went away by other means
    decision = ctx.wait_for_external_event("decision")
    for tier in TIERS:
        ctx.set_custom_status(json.dumps({"awaiting": tier, "hash": h, "proposal": proposal}))
        deadline = ctx.create_timer(timedelta(seconds=APPROVAL_SECONDS))
        while True:
            first = yield wf.when_any([decision, resolved, deadline])
            if first == deadline:
                break
            if first == resolved:
                return {"outcome": "resolved_elsewhere", "proposal": proposal, "hash": h}
            d = decision.get_result() or {}
            decision = ctx.wait_for_external_event("decision")
            # A decision counts only for the exact proposal it names and from a named approver.
            if d.get("hash") != h or not d.get("approver") or d.get("decision") not in ("approve", "reject"):
                continue
            grant = {"approver": d["approver"], "decision": d["decision"], "hash": h,
                     "tier": tier, "at": ctx.current_utc_datetime.isoformat()}
            if d["decision"] == "reject":
                return {"outcome": "rejected", "proposal": proposal, "grant": grant}
            r = yield ctx.call_activity(
                "commit", app_id=EXECUTOR_APP, retry_policy=RETRY,
                input={"rule": rule, "key": key, "fix_type": proposal["fix_type"],
                       "params": proposal["params"], "hash": h, "approver": grant["approver"]},
            )
            if r["status"] == "stale":  # the data changed after approval; nothing was applied
                return {"outcome": "recommendation", "text": r.get("error", ""), "proposal": proposal, "grant": grant}
            return {"outcome": r["status"], "proposal": proposal, "grant": grant}
    return {"outcome": "unattended", "proposal": proposal, "hash": h}


# Registered by name, not by decorator, so the function stays callable from tests.
runtime.register_workflow(handle_discrepancy, name="handle_discrepancy")


def run_id(rule: str, key, episode="1") -> str:
    # ponytail: the trigger supplies the episode; a discrepancy that recurs needs a new one.
    return f"{rule}-{key}-{episode}"


class Api(BaseHTTPRequestHandler):
    """Start a run, record a decision, look a run up. Reachable only through the gateway."""

    client: wf.DaprWorkflowClient = None

    def _send(self, code: int, body: dict):
        data = json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _body(self) -> dict:
        return json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0")) or 0) or b"{}")

    def do_GET(self):
        if not self.path.startswith("/runs/"):
            return self._send(404, {})
        state = self.client.get_workflow_state(self.path[len("/runs/"):])
        if state is None:
            return self._send(404, {})
        self._send(200, {
            "status": state.runtime_status.name,
            "awaiting": json.loads(state.serialized_custom_status or "null"),
            "result": json.loads(state.serialized_output or "null"),
        })

    def do_POST(self):
        try:
            b = self._body()
            if self.path == "/runs":
                if b["rule"] not in RULES:
                    return self._send(400, {"error": "unknown rule"})
                rid = run_id(b["rule"], int(b["key"]), b.get("episode", "1"))
                if self.client.get_workflow_state(rid) is None:
                    self.client.schedule_new_workflow(
                        "handle_discrepancy", input={"rule": b["rule"], "key": int(b["key"])}, instance_id=rid
                    )
                return self._send(200, {"run": rid})
            if self.path == "/decisions":
                # ponytail: the approver comes from a header until the gateway verifies a
                # Keycloak token and sets it (ADR 0009); nothing but the gateway may reach this.
                approver = self.headers.get("x-approver", "")
                self.client.raise_workflow_event(
                    b["run"], "decision", data={"approver": approver, "hash": b["hash"], "decision": b["decision"]}
                )
                return self._send(202, {})
            if self.path == "/resolved":
                self.client.raise_workflow_event(run_id(b["rule"], int(b["key"]), b.get("episode", "1")), "resolved", data={})
                return self._send(202, {})
            self._send(404, {})
        except (KeyError, ValueError) as e:
            self._send(400, {"error": str(e)})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    runtime.start()
    Api.client = wf.DaprWorkflowClient()
    server = ThreadingHTTPServer(("0.0.0.0", 8080), Api)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    signal.pause()
