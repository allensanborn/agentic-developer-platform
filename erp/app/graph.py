"""The diagnosis graph: gather the facts, let the model choose a declared fix, validate it.

Reads go through a read-only database role; the model is reached through the AI gateway
as this workload's own identity. Nothing here can change data, and what comes out is only
a proposal for the controller to have checked.
"""

import json
import os
import urllib.request
from typing import TypedDict

from langgraph.graph import END, START, StateGraph

from rules import RULES

GATEWAY = os.environ.get("AI_GATEWAY_URL", "http://ai-gateway.ai-gateway.svc.cluster.local:8080")
TOKEN_FILE = os.environ.get("AI_GATEWAY_TOKEN_FILE", "/var/run/secrets/ai-gateway/token")
ALIAS = os.environ.get("DIAGNOSIS_ALIAS", "smart")
READ_BINDING = os.environ.get("READ_BINDING", "erp-read")
MAX_ANSWERS = 2  # the model gets one chance to correct an answer that does not validate


def read(sql: str, params: list) -> list:
    from dapr.clients import DaprClient

    with DaprClient() as d:
        resp = d.invoke_binding(READ_BINDING, "query", binding_metadata={"sql": sql, "params": json.dumps(params)})
    return json.loads(resp.data)


def chat(alias: str, system: str, user: str) -> dict:
    with open(TOKEN_FILE) as f:  # read per call: the kubelet rotates it
        token = f.read().strip()
    body = {
        "model": alias, "temperature": 0, "seed": 0, "max_tokens": 200,
        "response_format": {"type": "json_object"},
        "messages": [{"role": "system", "content": system}, {"role": "user", "content": user}],
    }
    req = urllib.request.Request(
        f"{GATEWAY}/v1/chat/completions", data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=600) as resp:
        out = json.load(resp)
    return {"model": out["model"], "tokens": out["usage"]["total_tokens"], "text": out["choices"][0]["message"]["content"]}


class State(TypedDict, total=False):
    rule: str
    key: int
    rejected: list  # proposals from earlier attempts that failed the controller's check
    context: dict
    answer: str
    error: str
    answers: int
    model: str
    tokens: int
    result: dict


def gather(s: State) -> dict:
    rule = RULES[s["rule"]]
    return {"context": {
        name: [dict(zip(rule["columns"][name], row)) for row in read(sql, [s["key"]])]
        for name, sql in rule["context"].items()
    }}


def prompts(s: State) -> tuple[str, str]:
    rule = RULES[s["rule"]]
    system = (
        "You diagnose one data discrepancy in an ERP database and choose how to fix it.\n"
        f"Rule broken: {rule['description']}\n{rule['guidance']}\n"
        "Fix types you may choose from:\n"
        + "\n".join(f"- {n}: {t['description']} params: {json.dumps(t['params'])}" for n, t in rule["fix_types"].items())
        + '\nAnswer with one JSON object: {"kind": "fix", "fix_type": "<name>", "params": {...}, "evidence": "<one sentence>"}'
        + '\nIf no fix type fits, answer {"kind": "recommendation", "text": "<what a person should look at>"}.'
    )
    user = f"Discrepancy key: {s['key']}\nData:\n{json.dumps(s['context'])}"
    if s.get("rejected"):
        user += f"\nAlready tried and failed the check, do not repeat: {json.dumps(s['rejected'])}"
    if s.get("error"):
        user += f"\nYour previous answer was invalid ({s['error']}): {s['answer']}"
    return system, user


def decide(s: State) -> dict:
    out = chat(ALIAS, *prompts(s))
    return {"answer": out["text"], "model": out["model"],
            "tokens": s.get("tokens", 0) + out["tokens"], "answers": s.get("answers", 0) + 1}


def problem(s: State, a) -> str:
    """Why the model's answer cannot be used as it stands, or '' if it can."""
    if not isinstance(a, dict) or a.get("kind") not in ("fix", "recommendation"):
        return "not an object with kind fix or recommendation"
    if a["kind"] == "recommendation":
        return "" if isinstance(a.get("text"), str) and a["text"] else "recommendation needs text"
    declared = RULES[s["rule"]]["fix_types"].get(a.get("fix_type"))
    if declared is None:
        return "fix_type is not one of the declared fix types"
    params = a.get("params")
    if not isinstance(params, dict) or set(params) != set(declared["params"]):
        return f"params must be exactly {sorted(declared['params'])}"
    if any(type(v) is not int for v in params.values()):
        return "params must be integers"
    lines = {row["invoice_line_id"] for row in s["context"].get("lines", [])}
    if "invoice_line_id" in params and params["invoice_line_id"] not in lines:
        return "invoice_line_id is not a line of this invoice"
    return ""


def validate(s: State) -> dict:
    try:
        a = json.loads(s["answer"])
    except ValueError:
        a = None
    err = problem(s, a)
    if err:
        return {"error": err}
    out = {k: a[k] for k in (("kind", "fix_type", "params") if a["kind"] == "fix" else ("kind", "text"))}
    if a["kind"] == "fix":
        out["evidence"] = str(a.get("evidence", ""))[:500]
    return {"error": "", "result": out}


def after_validate(s: State) -> str:
    return END if not s["error"] or s["answers"] >= MAX_ANSWERS else "decide"


builder = StateGraph(State)
builder.add_node("gather", gather)
builder.add_node("decide", decide)
builder.add_node("validate", validate)
builder.add_edge(START, "gather")
builder.add_edge("gather", "decide")
builder.add_edge("decide", "validate")
builder.add_conditional_edges("validate", after_validate, {END: END, "decide": "decide"})
graph = builder.compile()


def diagnose(rule: str, key: int, rejected: list) -> dict:
    s = graph.invoke({"rule": rule, "key": key, "rejected": rejected}, {"recursion_limit": 12})
    result = s.get("result") or {"kind": "recommendation", "text": f"the model gave no usable answer: {s.get('error')}"}
    return {**result, "model": s.get("model"), "tokens": s.get("tokens", 0)}
