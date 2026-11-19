"""A durable research agent.

The workflow is deterministic and durable (Dapr Workflow); the model calls are activities,
so a crash mid-run resumes from recorded results instead of asking the model again. The
agent holds no model credential: it calls the AI gateway as itself, and asks for a
capability ("fast", "smart"), not a model.
"""

import json
import os
import signal
import sys
import urllib.error
import urllib.request
from datetime import timedelta

import dapr.ext.workflow as wf

GATEWAY = os.environ.get("AI_GATEWAY_URL", "http://ai-gateway.ai-gateway.svc.cluster.local:8080")
MCP_URL = os.environ.get("MCP_URL", "http://ai-gateway.ai-gateway.svc.cluster.local:8081/mcp")
TOKEN_FILE = os.environ.get("AI_GATEWAY_TOKEN_FILE", "/var/run/secrets/ai-gateway/token")

runtime = wf.WorkflowRuntime()


def token() -> str:
    # Read the token on every call: the kubelet rotates it, a cached copy would expire.
    with open(TOKEN_FILE) as f:
        return f.read().strip()


def chat(alias: str, prompt: str) -> dict:
    body = {"model": alias, "max_tokens": 400, "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(
        f"{GATEWAY}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token()}", "Content-Type": "application/json"},
    )
    with urllib.request.urlopen(req, timeout=300) as resp:
        out = json.load(resp)
    # `model` is what actually answered, which differs from the alias after a fallback.
    return {
        "alias": alias,
        "model": out["model"],
        "tokens": out["usage"]["total_tokens"],
        "text": out["choices"][0]["message"]["content"],
    }


@runtime.activity(name="call_model")
def call_model(ctx, req: dict) -> dict:
    return chat(req["alias"], req["prompt"])


def mcp_message(body: bytes) -> dict:
    """One JSON-RPC message from a streamable-HTTP MCP response: SSE `data:` or plain JSON."""
    text = body.decode()
    for line in text.splitlines():
        if line.startswith("data: "):
            return json.loads(line[len("data: "):])
    return json.loads(text)


def tool(name: str, arguments: dict) -> dict:
    """Call one MCP tool through the gateway, as this workload. A fresh session per call.

    ponytail: three requests per call (initialize, initialized, call); keep a session per
    worker if tool latency matters.
    """
    headers = {"Authorization": f"Bearer {token()}", "Content-Type": "application/json",
               "Accept": "application/json, text/event-stream"}

    def post(msg: dict, session: str | None = None):
        h = {**headers, **({"mcp-session-id": session} if session else {})}
        req = urllib.request.Request(MCP_URL, data=json.dumps({"jsonrpc": "2.0", **msg}).encode(), headers=h)
        try:
            return urllib.request.urlopen(req, timeout=30)
        except urllib.error.HTTPError as e:  # the gateway answers a hidden tool with a 400 JSON-RPC error
            return e

    with post({"id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "research-agent", "version": "1"}}}) as r:
        session = r.headers["mcp-session-id"]
    post({"method": "notifications/initialized"}, session).close()
    with post({"id": 2, "method": "tools/call", "params": {"name": name, "arguments": arguments}}, session) as r:
        out = mcp_message(r.read())
    if "error" in out:
        return {"tool": name, "error": out["error"]["message"]}
    return {"tool": name, "result": json.loads(out["result"]["content"][0]["text"])}


@runtime.activity(name="call_tool")
def call_tool(ctx, req: dict) -> dict:
    return tool(req["name"], req["arguments"])


@runtime.workflow(name="order_status")
def order_status(ctx: wf.DaprWorkflowContext, order_id: str):
    # The tool call is an activity like a model call: recorded, so a resumed run does not
    # look the order up again. Which tools this agent may call is the gateway's decision.
    found = yield ctx.call_activity(call_tool, input={"name": "lookup_order", "arguments": {"order_id": order_id}},
                                    retry_policy=RETRY)
    if "error" in found or "error" in found["result"]:
        return {"order": found, "reply": None}
    prompt = (
        "Write a two-sentence reply to a customer asking where their order is, from this order record:\n"
        + json.dumps(found["result"])
    )
    reply = yield ctx.call_activity(call_model, input={"alias": "smart", "prompt": prompt}, retry_policy=RETRY)
    return {"order": found, "reply": reply["text"], "model": reply["model"]}


RETRY = wf.RetryPolicy(first_retry_interval=timedelta(seconds=2), max_number_of_attempts=3, backoff_coefficient=2)


@runtime.workflow(name="research")
def research(ctx: wf.DaprWorkflowContext, question: str):
    # Cheap model drafts, stronger model reviews: routing by task, not frontier by default.
    draft = yield ctx.call_activity(call_model, input={"alias": "fast", "prompt": question}, retry_policy=RETRY)
    review_prompt = (
        f"Question: {question}\n\nDraft answer: {draft['text']}\n\n"
        "Correct any errors and reply with the improved answer only."
    )
    final = yield ctx.call_activity(call_model, input={"alias": "smart", "prompt": review_prompt}, retry_policy=RETRY)
    steps = [{k: s[k] for k in ("alias", "model", "tokens")} for s in (draft, final)]
    return {"answer": final["text"], "steps": steps}


def run(workflow, arg: str) -> dict:
    client = wf.DaprWorkflowClient()
    instance = client.schedule_new_workflow(workflow, input=arg)
    state = client.wait_for_workflow_completion(instance, timeout_in_seconds=600)
    return {"instance": instance, "status": state.runtime_status.name, "result": json.loads(state.serialized_output or "null")}


if __name__ == "__main__":
    commands = {"ask": research, "order": order_status}  # app.py ask "<question>" | app.py order ORD-1001
    if sys.argv[1:2] and sys.argv[1] in commands:
        print(json.dumps(run(commands[sys.argv[1]], sys.argv[2])))
    else:
        runtime.start()
        signal.pause()
