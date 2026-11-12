"""The graph with a scripted model: only a valid, declared fix comes out as a fix."""

import json

import graph

LINES = [[101, 5, 0.99, 1, 0.99, 0.99], [102, 6, 5.99, 1, 0.99, 5.99]]


def run(monkeypatch, answers):
    monkeypatch.setattr(graph, "read", lambda sql, params: [[7, 6.98, "2021-01-01"]] if "FROM invoice WHERE" in sql else LINES)
    seen = []

    def chat(alias, system, user):
        seen.append(user)
        return {"model": "scripted", "tokens": 10, "text": answers.pop(0)}

    monkeypatch.setattr(graph, "chat", chat)
    return graph.diagnose("invoice_total_mismatch", 7, []), seen


def fix(fix_type, **params):
    return json.dumps({"kind": "fix", "fix_type": fix_type, "params": params, "evidence": "because"})


def test_a_valid_fix_passes_through_with_the_model_and_token_count(monkeypatch):
    out, seen = run(monkeypatch, [fix("set_line_price_from_track", invoice_line_id=102)])
    assert out == {"kind": "fix", "fix_type": "set_line_price_from_track", "params": {"invoice_line_id": 102},
                   "evidence": "because", "model": "scripted", "tokens": 10}
    assert '"track_unit_price": 0.99' in seen[0]  # the gathered facts reach the model


def test_an_invalid_answer_gets_one_correction_then_becomes_a_recommendation(monkeypatch):
    bad = [
        "DROP TABLE invoice",  # not JSON
        fix("drop_table"),  # undeclared fix type
        fix("set_line_quantity", invoice_line_id=102),  # missing param
        fix("set_line_price_from_track", invoice_line_id=999),  # a line of some other invoice
        fix("set_line_price_from_track", invoice_line_id="102; DROP TABLE invoice"),  # not an integer
    ]
    for answer in bad:
        out, seen = run(monkeypatch, [answer, fix("set_invoice_total_from_lines")])
        assert out["fix_type"] == "set_invoice_total_from_lines" and len(seen) == 2 and "invalid" in seen[1]
        out, seen = run(monkeypatch, [answer, answer])
        assert out["kind"] == "recommendation" and "fix_type" not in out and len(seen) == 2


def test_the_model_may_decline(monkeypatch):
    out, _ = run(monkeypatch, [json.dumps({"kind": "recommendation", "text": "ask finance"})])
    assert out["kind"] == "recommendation" and out["text"] == "ask finance"
