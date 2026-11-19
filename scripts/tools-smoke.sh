#!/usr/bin/env bash
# End-to-end check of the tools stage (scripts/tools-up.sh): who may see and call which
# MCP tool, and that the tools are reachable only through the gateway. Every deny is
# paired with an allow that proves the path works at all.
set -uo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"

MCP=http://ai-gateway.ai-gateway.svc.cluster.local:8081/mcp
CURL=curlimages/curl:8.21.0@sha256:7c12af72ceb38b7432ab85e1a265cff6ae58e06f95539d539b654f2cfa64bb13
fails=0

probe() { # namespace: a long-lived curl pod to exec into
  kubectl run tools-smoke -n "$1" --image "$CURL" --restart=Never --overrides '{"spec":{
    "automountServiceAccountToken":false,
    "securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},
    "containers":[{"name":"c","image":"'"$CURL"'","command":["sleep","900"],
      "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
  kubectl wait -n "$1" pod/tools-smoke --for=condition=Ready --timeout=120s >/dev/null
}
cleanup() { for ns in agents default; do kubectl delete pod tools-smoke -n "$ns" --ignore-not-found >/dev/null 2>&1; done; }
trap cleanup EXIT
cleanup
probe agents; probe default

check() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected $2, got $3)"; fails=$((fails + 1)); fi
}
status() { # namespace, url, [bearer token]: HTTP status of an MCP initialize, 000 when blocked
  kubectl exec -n "$1" tools-smoke -- curl -s -m 8 -o /dev/null -w '%{http_code}' "$2" \
    ${3:+-H "Authorization: Bearer $3"} -H 'Accept: application/json, text/event-stream' \
    -H 'Content-Type: application/json' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' \
    2>/dev/null | tail -c 3
}
# One MCP request in a fresh session (initialize, initialized, then the request), from the
# agents namespace: prints the JSON-RPC response (an SSE `data:` line, or plain JSON on error).
# shellcheck disable=SC2016 # the script runs in the pod, with its arguments as $1..$4
rpc() { # token, method, params JSON
  kubectl exec -n agents tools-smoke -- sh -c '
    u=$1; t=$2; a="Accept: application/json, text/event-stream"; c="Content-Type: application/json"
    s=$(curl -s -m 20 -D - -o /dev/null "$u" -H "Authorization: Bearer $t" -H "$a" -H "$c" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":{},\"clientInfo\":{\"name\":\"smoke\",\"version\":\"0\"}}}" |
      tr -d "\r" | sed -n "s/^[Mm]cp-[Ss]ession-[Ii]d: //p")
    curl -s -m 20 -o /dev/null "$u" -H "Authorization: Bearer $t" -H "$a" -H "$c" -H "mcp-session-id: $s" \
      -d "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}"
    curl -s -m 20 "$u" -H "Authorization: Bearer $t" -H "$a" -H "$c" -H "mcp-session-id: $s" \
      -d "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"$3\",\"params\":$4}" |
      sed -n "s/^data: //; /^{/p"' \
    _ "$MCP" "$1" "$2" "$3" 2>/dev/null
}
tools() { rpc "$1" tools/list '{}' | jq -r '[.result.tools[].name] | sort | join(" ")' 2>/dev/null; }
call() { # token, tool, arguments JSON: the tool's JSON result, or the error message
  rpc "$1" tools/call "{\"name\":\"$2\",\"arguments\":$3}" |
    jq -c 'if .error then {error: .error.message} else (.result.content[0].text | fromjson) end' 2>/dev/null
}

research=$(kubectl create token research-agent -n agents --audience ai-gateway --duration 10m)
intern=$(kubectl create token intern -n agents --audience ai-gateway --duration 10m)
wrong_aud=$(kubectl create token intern -n agents --duration 10m)

echo "--- identity"
check "no token is rejected" 401 "$(status agents $MCP)"
check "a token for another audience is rejected" 401 "$(status agents $MCP "$wrong_aud")"
check "a ServiceAccount token is accepted" 200 "$(status agents $MCP "$intern")"

echo "--- which tools each identity can see"
check "research-agent sees lookup_order and initiate_return" "initiate_return lookup_order" "$(tools "$research")"
check "intern sees lookup_order only" "lookup_order" "$(tools "$intern")"
echo "      check_inventory is in neither list: no rule allows it"

echo "--- calling tools (the workshop's server.py, reading DynamoDB on floci)"
check "lookup_order reads the order from the table" "Jane Doe shipped" \
  "$(call "$research" lookup_order '{"order_id":"ORD-1001"}' | jq -r '"\(.customer) \(.status)"')"
check "research-agent may start a return" RET-1001 \
  "$(call "$research" initiate_return '{"order_id":"ORD-1001","reason":"smoke"}' | jq -r .return_id)"
check "the tool's own rule still applies (no return before shipping)" true \
  "$(call "$research" initiate_return '{"order_id":"ORD-1003","reason":"smoke"}' | jq -r '.error // "" | test("hasn.t shipped")')"
# A tool the caller may not use does not exist for it: the gateway answers as for any unknown tool.
check "intern calling a tool it cannot see: unknown to the gateway" "unknown resource" \
  "$(call "$intern" initiate_return '{"order_id":"ORD-1001","reason":"smoke"}' | jq -r .error)"
check "nobody can call check_inventory" "unknown resource" \
  "$(call "$research" check_inventory '{"product_name":"Laptop"}' | jq -r .error)"

echo "--- the agent calls a tool as a workflow activity (agent/app.py order_status)"
since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
out=$(kubectl exec -n agents deploy/research-agent -c agent -- python app.py order ORD-1001 2>/dev/null | tail -n1)
check "the order workflow completes" COMPLETED "$(jq -r .status <<<"$out" 2>/dev/null)"
check "it got the order from the tool" "lookup_order Jane Doe" \
  "$(jq -r '"\(.result.order.tool) \(.result.order.result.customer)"' <<<"$out" 2>/dev/null)"
check "the gateway logged that tool call as research-agent" 1 \
  "$(kubectl logs -n ai-gateway deploy/ai-gateway --since-time="$since" 2>/dev/null | grep 'listener=mcp' |
    grep 'http.status=200' | grep 'jwt.sub=system:serviceaccount:agents:research-agent' |
    grep 'mcp.method.name=tools/call' | grep -c 'gen_ai.tool.name=lookup_order')"
check "and a model wrote the reply" true "$(jq -r '(.result.reply // "") | length > 0' <<<"$out" 2>/dev/null)"
out=$(kubectl exec -n agents deploy/research-agent -c agent -- python app.py order ORD-9999 2>/dev/null | tail -n1)
check "an unknown order ends the run without asking a model" "null null" \
  "$(jq -r '"\(.result.reply) \(.result.model)"' <<<"$out" 2>/dev/null)"

echo "--- network isolation"
check "agents cannot reach the tools server directly" 000 "$(status agents http://orders-mcp.tools.svc.cluster.local:8080/mcp)"
check "a namespace without the client label cannot reach the tools listener" 000 "$(status default $MCP "$intern")"
check "the tools server cannot reach the internet" blocked \
  "$(kubectl exec -n tools deploy/orders-mcp -- python -c "import socket
try: socket.create_connection(('1.1.1.1', 443), 4); print('reached')
except OSError: print('blocked')" 2>/dev/null)"

echo
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
