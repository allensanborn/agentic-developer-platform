#!/usr/bin/env bash
# End-to-end check of the sandbox stage (scripts/sandbox-up.sh): model-written code runs in
# a gVisor sandbox with its own kernel, an enforced seccomp profile, no credential and no
# network, and only research-agent may ask for it. Every deny is paired with an allow.
set -uo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"

MCP=http://ai-gateway.ai-gateway.svc.cluster.local:8081/code-mcp
CURL=curlimages/curl:8.21.0@sha256:7c12af72ceb38b7432ab85e1a265cff6ae58e06f95539d539b654f2cfa64bb13
NS=agent-sandbox
CLAIM=smoke-$(date +%s)
fails=0

check() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected $2, got $3)"; fails=$((fails + 1)); fi
}
cleanup() {
  kubectl delete pod sandbox-smoke -n agents --ignore-not-found >/dev/null 2>&1
  kubectl delete pod sandbox-control -n "$NS" --ignore-not-found >/dev/null 2>&1
  kubectl delete sandboxclaim "$CLAIM" -n "$NS" --ignore-not-found >/dev/null 2>&1
}
trap cleanup EXIT
in_pod() { kubectl exec -n "$NS" "$1" -- python3 -c "$2" 2>/dev/null; }
# A TCP connect from inside a pod: "reached" or "blocked".
PROBE='import socket,sys
try: socket.create_connection((sys.argv[1], int(sys.argv[2])), 4); print("reached")
except OSError: print("blocked")'
reach() { kubectl exec -n "$NS" "$1" -- python3 -c "$PROBE" "$2" "$3" 2>/dev/null; }

echo "--- the warm pool"
# Readiness, not apply success: Pod Security refuses a non-compliant pod silently.
check "both warm-pool sandboxes are Ready" 2 \
  "$(kubectl get pods -n $NS -l agents.x-k8s.io/warm-pool-sandbox -o json | jq '[.items[] | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))] | length')"

echo "--- a claimed sandbox, as the broker gets one"
kubectl apply -f - >/dev/null <<EOF
apiVersion: extensions.agents.x-k8s.io/v1beta1
kind: SandboxClaim
metadata: {name: $CLAIM, namespace: $NS}
spec: {warmPoolRef: {name: gvisor-python-pool}}
EOF
kubectl wait sandboxclaim "$CLAIM" -n $NS --for=condition=Ready --timeout=120s >/dev/null
sb=$(kubectl get sandboxclaim "$CLAIM" -n $NS -o jsonpath='{.status.sandbox.name}')
check "the claimed pod has left the pool (the label the workshop's policy selected is gone)" "" \
  "$(kubectl get pod "$sb" -n $NS -o jsonpath='{.metadata.labels.agents\.x-k8s\.io/warm-pool-sandbox}')"
node_kernel=$(docker exec "k3d-$CLUSTER-agent-0" uname -r)
sb_kernel=$(in_pod "$sb" 'import os; print(os.uname().release)')
check "it runs its own kernel (gVisor), not the node's ($node_kernel)" yes \
  "$([ -n "$sb_kernel" ] && [ "$sb_kernel" != "$node_kernel" ] && echo yes || echo "no: $sb_kernel")"
check "its seccomp profile is enforced" 2 \
  "$(in_pod "$sb" 'print([l.split()[1] for l in open("/proc/self/status") if l.startswith("Seccomp:")][0])')"
check "a namespace escape primitive is refused (unshare CLONE_NEWUSER)" EPERM \
  "$(in_pod "$sb" 'import ctypes,errno; l=ctypes.CDLL(None, use_errno=True); l.unshare(0x10000000); print(errno.errorcode.get(ctypes.get_errno(), "allowed"))')"
check "it mounts no Kubernetes credential" False \
  "$(in_pod "$sb" 'import os; print(os.path.exists("/var/run/secrets/kubernetes.io"))')"

# The control: the same runtime and image in the same namespace, not selected by the air gap.
api=$(kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip} {.subsets[0].ports[0].port}' 2>/dev/null)
kubectl run sandbox-control -n $NS --image adp/python-sandbox:dev --image-pull-policy Never --restart=Never \
  --overrides '{"spec":{"runtimeClassName":"gvisor","automountServiceAccountToken":false,
    "securityContext":{"runAsNonRoot":true,"runAsUser":1000,"seccompProfile":{"type":"RuntimeDefault"}},
    "containers":[{"name":"sandbox-control","image":"adp/python-sandbox:dev","imagePullPolicy":"Never",
      "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
kubectl wait pod sandbox-control -n $NS --for=condition=Ready --timeout=120s >/dev/null
check "control (same runtime, not air-gapped) reaches the internet" reached "$(reach sandbox-control 1.1.1.1 443)"
check "the claimed sandbox cannot reach the internet" blocked "$(reach "$sb" 1.1.1.1 443)"
check "control reaches the Kubernetes API" reached "$(reach sandbox-control "${api% *}" "${api#* }")"
check "the claimed sandbox cannot reach the Kubernetes API" blocked "$(reach "$sb" "${api% *}" "${api#* }")"

echo "--- run_python through the gateway"
kubectl run sandbox-smoke -n agents --image "$CURL" --restart=Never --overrides '{"spec":{
  "automountServiceAccountToken":false,
  "securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},
  "containers":[{"name":"c","image":"'"$CURL"'","command":["sleep","900"],
    "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
kubectl wait -n agents pod/sandbox-smoke --for=condition=Ready --timeout=120s >/dev/null
# One MCP request in a fresh session (initialize, initialized, then the request), from the
# agents namespace: prints the JSON-RPC response (an SSE `data:` line, or plain JSON on error).
# shellcheck disable=SC2016 # the script runs in the pod, with its arguments as $1..$4
rpc() { # token, method, params JSON
  kubectl exec -n agents sandbox-smoke -- sh -c '
    u=$1; t=$2; a="Accept: application/json, text/event-stream"; c="Content-Type: application/json"
    s=$(curl -s -m 20 -D - -o /dev/null "$u" -H "Authorization: Bearer $t" -H "$a" -H "$c" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"smoke\",\"version\":\"0\"}}}" |
      tr -d "\r" | sed -n "s/^[Mm]cp-[Ss]ession-[Ii]d: //p")
    curl -s -m 20 -o /dev/null "$u" -H "Authorization: Bearer $t" -H "$a" -H "$c" -H "mcp-session-id: $s" \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
    curl -s -m 200 "$u" -H "Authorization: Bearer $t" -H "$a" -H "$c" -H "mcp-session-id: $s" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$3\",\"params\":$4}" |
      sed -n "s/^data: //; /^{/p"' \
    _ "$MCP" "$1" "$2" "$3" 2>/dev/null
}
tools() { rpc "$1" tools/list '{}' | jq -r '[.result.tools[].name] | sort | join(" ")' 2>/dev/null; }
call() { # token, arguments JSON for run_python: its JSON result, or the error message
  rpc "$1" tools/call "{\"name\":\"run_python\",\"arguments\":$2}" |
    jq -c 'if .error then {error: .error.message} else (.result.content[0].text | fromjson) end' 2>/dev/null
}
research=$(kubectl create token research-agent -n agents --audience ai-gateway --duration 10m)
intern=$(kubectl create token intern -n agents --audience ai-gateway --duration 10m)
check "research-agent sees run_python" run_python "$(tools "$research")"
check "intern does not" "" "$(tools "$intern")"
code='import json; rows = json.load(open("orders.json")); print(len(rows), round(sum(r["total"] for r in rows), 2))'
out=$(call "$research" "$(jq -nc --arg c "$code" '{code: $c, period: "2026-Q1"}')")
check "run_python computes over the broker's rows in a sandbox (2026-Q1)" "139 rows, exit 0" \
  "$(jq -r '"\(.row_count) rows, exit \(.exit_code)"' <<<"$out" 2>/dev/null)"
echo "      stdout: $(jq -r .stdout <<<"$out" 2>/dev/null | tr -d '\n')"
check "intern calling run_python: unknown to the gateway" "unknown resource" \
  "$(call "$intern" '{"code":"print(1)","period":"2026-Q1"}' | jq -r .error)"
check "agents cannot reach the broker directly" 000 \
  "$(kubectl exec -n agents sandbox-smoke -- curl -s -m 5 -o /dev/null -w '%{http_code}' http://code-executor.tools.svc.cluster.local:8080/mcp 2>/dev/null | tail -c 3)"

echo
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
