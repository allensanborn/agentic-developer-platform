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
import urllib.request
from datetime import timedelta

import dapr.ext.workflow as wf

GATEWAY = os.environ.get("AI_GATEWAY_URL", "http://ai-gateway.ai-gateway.svc.cluster.local:8080")
TOKEN_FILE = os.environ.get("AI_GATEWAY_TOKEN_FILE", "/var/run/secrets/ai-gateway/token")

runtime = wf.WorkflowRuntime()


def chat(alias: str, prompt: str) -> dict:
    # Read the token on every call: the kubelet rotates it, a cached copy would expire.
    with open(TOKEN_FILE) as f:
        token = f.read().strip()
    body = {"model": alias, "max_tokens": 400, "messages": [{"role": "user", "content": prompt}]}
    req = urllib.request.Request(
        f"{GATEWAY}/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Authorization": f"Bearer {token}", "Content-Type": "application/json"},
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


def ask(question: str) -> dict:
    client = wf.DaprWorkflowClient()
    instance = client.schedule_new_workflow(research, input=question)
    state = client.wait_for_workflow_completion(instance, timeout_in_seconds=600)
    return {"instance": instance, "status": state.runtime_status.name, "result": json.loads(state.serialized_output or "null")}


if __name__ == "__main__":
    if sys.argv[1:2] == ["ask"]:
        print(json.dumps(ask(sys.argv[2])))
    else:
        runtime.start()
        signal.pause()
