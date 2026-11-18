"""Drives the run workflow with a fake context: what may and may not lead to a commit."""

import json
from datetime import datetime

import controller
from controller import handle_discrepancy, proposal_hash

GOOD = {"kind": "fix", "fix_type": "set_invoice_total_from_lines", "params": {}, "evidence": "e"}
H = proposal_hash({"run": "run-1", "rule": "invoice_total_mismatch", "key": 7, **{k: GOOD[k] for k in ("fix_type", "params")}})


class Task:
    def __init__(self, kind, name=None, input=None):
        self.kind, self.name, self.input, self.result = kind, name, input, None

    def get_result(self):
        return self.result


class Ctx:
    current_utc_datetime = datetime(2026, 1, 1)
    instance_id = "run-1"

    def __init__(self):
        self.calls, self.status = [], None

    def call_activity(self, name, *, input=None, app_id=None, retry_policy=None):
        self.calls.append((name, app_id, input))
        return Task("activity", name, input)

    def wait_for_external_event(self, name):
        return Task(name)

    def create_timer(self, delay):
        return Task("deadline")

    def set_custom_status(self, value):
        self.status = json.loads(value)


def drive(monkeypatch, activities, events):
    """activities: name -> results in call order. events: ("decision", data) | ("resolved",) | ("deadline",)."""
    monkeypatch.setattr(controller.wf, "when_any", lambda tasks: tasks)
    ctx = Ctx()
    gen = handle_discrepancy(ctx, {"rule": "invoice_total_mismatch", "key": 7})
    try:
        y = next(gen)
        while True:
            if isinstance(y, list):
                kind, *data = events.pop(0)
                task = next(t for t in y if t.kind == kind)
                task.result = data[0] if data else None
                y = gen.send(task)
            else:
                y = gen.send(activities[y.name].pop(0))
    except StopIteration as stop:
        return stop.value, [c[0] for c in ctx.calls], ctx


def decision(**kw):
    return ("decision", {"approver": "alice", "hash": H, "decision": "approve", **kw})


def test_approved_fix_is_committed_with_its_hash_and_approver(monkeypatch):
    acts = {"diagnose": [GOOD], "dry_run": [{"resolves": True}], "commit": [{"status": "committed"}]}
    out, calls, ctx = drive(monkeypatch, acts, [decision()])
    assert out["outcome"] == "committed" and calls == ["diagnose", "dry_run", "commit"]
    name, app, sent = ctx.calls[-1]
    assert app == controller.EXECUTOR_APP and sent["hash"] == H and sent["approver"] == "alice"
    assert ctx.status["hash"] == H


def test_nothing_but_a_valid_approval_commits(monkeypatch):
    acts = {"diagnose": [GOOD], "dry_run": [{"resolves": True}], "commit": []}
    events = [
        decision(hash="some-other-proposal"),  # approval of a different proposal
        decision(approver=""),  # nobody named
        decision(decision="maybe"),
        ("deadline",),  # first tier lapses: escalate
        ("deadline",),  # second tier lapses: give up, never approve
    ]
    out, calls, _ = drive(monkeypatch, acts, events)
    assert out["outcome"] == "unattended" and "commit" not in calls


def test_reject_and_resolved_elsewhere_do_not_commit(monkeypatch):
    for event, outcome in ((decision(decision="reject"), "rejected"), (("resolved",), "resolved_elsewhere")):
        acts = {"diagnose": [GOOD], "dry_run": [{"resolves": True}], "commit": []}
        out, calls, _ = drive(monkeypatch, acts, [event])
        assert out["outcome"] == outcome and "commit" not in calls


def test_undeclared_fix_type_never_reaches_the_executor(monkeypatch):
    bad = {**GOOD, "fix_type": "drop_table"}
    acts = {"diagnose": [bad, GOOD], "dry_run": [{"resolves": True}], "commit": [{"status": "committed"}]}
    out, calls, ctx = drive(monkeypatch, acts, [decision()])
    assert calls == ["diagnose", "diagnose", "dry_run", "commit"]
    assert ctx.calls[1][2]["rejected"][0]["fix_type"] == "drop_table"  # fed back to the next attempt


def test_attempts_are_bounded_and_end_as_a_recommendation(monkeypatch):
    acts = {"diagnose": [GOOD, GOOD], "dry_run": [{"resolves": False}, {"resolves": False, "error": "x"}]}
    out, calls, _ = drive(monkeypatch, acts, [])
    assert out["outcome"] == "recommendation" and calls == ["diagnose", "dry_run"] * 2


def test_stale_commit_is_not_reported_as_committed(monkeypatch):
    acts = {"diagnose": [GOOD], "dry_run": [{"resolves": True}], "commit": [{"status": "stale", "error": "changed"}]}
    out, _, _ = drive(monkeypatch, acts, [decision()])
    assert out["outcome"] == "recommendation"


def test_the_same_fix_in_a_later_run_is_a_different_proposal():
    fix = {"rule": "invoice_total_mismatch", "key": 7, "fix_type": "set_invoice_total_from_lines", "params": {}}
    assert proposal_hash({"run": "a", **fix}) != proposal_hash({"run": "b", **fix})
