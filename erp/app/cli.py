"""Operator commands, run inside the controller pod: start | show | decide | resolved."""

import json
import sys
import urllib.error
import urllib.request


def http(method: str, path: str, body=None, headers=None):
    req = urllib.request.Request(
        f"http://127.0.0.1:8080{path}", method=method,
        data=None if body is None else json.dumps(body).encode(), headers=headers or {},
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            return json.load(r)
    except urllib.error.HTTPError as e:
        return {"http": e.code, **json.load(e)}


if __name__ == "__main__":
    cmd, a = sys.argv[1], sys.argv[2:]
    if cmd == "start":  # start <rule> <key> [episode]
        out = http("POST", "/runs", {"rule": a[0], "key": a[1], "episode": a[2] if len(a) > 2 else "1"})
    elif cmd == "show":  # show <run>
        out = http("GET", f"/runs/{a[0]}")
    elif cmd == "decide":  # decide <run> <hash> approve|reject <approver>
        out = http("POST", "/decisions", {"run": a[0], "hash": a[1], "decision": a[2]}, {"x-approver": a[3]})
    elif cmd == "resolved":  # resolved <rule> <key> [episode]
        out = http("POST", "/resolved", {"rule": a[0], "key": a[1], "episode": a[2] if len(a) > 2 else "1"})
    else:
        sys.exit(f"unknown command {cmd}")
    print(json.dumps(out))
