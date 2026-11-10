#!/usr/bin/env bash
# End-to-end check of the security properties the platform claims, against the live
# cluster. Every deny is paired with an allow that proves the path works at all.
set -uo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"

GW=http://ai-gateway.ai-gateway.svc.cluster.local:8080
CURL=curlimages/curl:8.21.0@sha256:7c12af72ceb38b7432ab85e1a265cff6ae58e06f95539d539b654f2cfa64bb13
fails=0

probe() { # namespace: a long-lived curl pod to exec into
  kubectl run adp-smoke -n "$1" --image "$CURL" --restart=Never --overrides '{"spec":{
    "automountServiceAccountToken":false,
    "securityContext":{"runAsNonRoot":true,"runAsUser":10001,"seccompProfile":{"type":"RuntimeDefault"}},
    "containers":[{"name":"c","image":"'"$CURL"'","command":["sleep","900"],
      "securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null
  kubectl wait -n "$1" pod/adp-smoke --for=condition=Ready --timeout=120s >/dev/null
}
cleanup() { for ns in agents default; do kubectl delete pod adp-smoke -n "$ns" --ignore-not-found >/dev/null 2>&1; done; }
trap cleanup EXIT
cleanup
probe agents; probe default

check() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected $2, got $3)"; fails=$((fails + 1)); fi
}
status() { # namespace, url, [bearer token]: HTTP status, or 000 when the connection is blocked
  kubectl exec -n "$1" adp-smoke -- curl -s -m 8 -o /dev/null -w '%{http_code}' \
    ${3:+-H "Authorization: Bearer $3"} "$2" 2>/dev/null | tail -c 3
}
chat() { # token, alias: "<status> <model that answered>"
  kubectl exec -n agents adp-smoke -- curl -s -m 180 -w '\n%{http_code}' "$GW/v1/chat/completions" \
    -H "Authorization: Bearer $1" -H 'Content-Type: application/json' \
    -d '{"model":"'"$2"'","max_tokens":16,"messages":[{"role":"user","content":"Reply with one word: hello"}]}' |
    { body=$(cat); echo "$(tail -n1 <<<"$body") $(sed '$d' <<<"$body" | jq -r '.model // empty' 2>/dev/null)"; }
}

intern=$(kubectl create token intern -n agents --audience ai-gateway --duration 10m)
research=$(kubectl create token research-agent -n agents --audience ai-gateway --duration 10m)
wrong_aud=$(kubectl create token intern -n agents --duration 10m)

echo "--- identity"
check "no token is rejected" 401 "$(status agents $GW/v1/models)"
check "a token for another audience is rejected" 401 "$(status agents $GW/v1/models "$wrong_aud")"
read -r code model <<<"$(chat "$intern" fast)"
check "intern may call fast" 200 "$code"
check "fast is served by the local 1B model" llama3.2:1b "$model"

echo "--- authorization and routing"
read -r code _ <<<"$(chat "$intern" smart)"
check "intern may not call smart" 403 "$code"
read -r code model <<<"$(chat "$research" smart)"
check "research-agent may call smart" 200 "$code"
echo "      smart was answered by: $model (llama3.2:3b means the hosted provider failed over)"
read -r code _ <<<"$(chat "$research" llama-3b)"
check "internal models cannot be requested directly" 404 "$code"

echo "--- network isolation"
check "a namespace without the client label cannot reach the gateway" 000 "$(status default $GW/v1/models "$intern")"
check "agents cannot reach the local models directly" 000 "$(status agents http://ollama.models.svc.cluster.local:11434/api/tags)"
check "agents cannot reach the internet" 000 "$(status agents https://openrouter.ai)"

echo "--- credentials"
check "the provider key exists only in the gateway namespace" 1 \
  "$(kubectl get secret -A -o json | jq '[.items[] | select(.metadata.name == "openrouter-apikey") | .metadata.namespace] | unique | length')"
check "the agent pod mounts no Kubernetes API token" false \
  "$(kubectl get deploy research-agent -n agents -o jsonpath='{.spec.template.spec.automountServiceAccountToken}')"

echo "--- durable agent (Dapr Workflow, state in DynamoDB)"
out=$(kubectl exec -n agents deploy/research-agent -c agent -- python app.py ask "What is the capital of France?" 2>/dev/null | tail -n1)
check "the research workflow completes" COMPLETED "$(jq -r .status <<<"$out" 2>/dev/null)"
check "draft used the fast alias, review the smart alias" "fast smart" "$(jq -r '[.result.steps[].alias] | join(" ")' <<<"$out" 2>/dev/null)"
echo "      $(jq -c .result.steps <<<"$out" 2>/dev/null)"

echo
if [ "$fails" -ne 0 ]; then echo "$fails check(s) failed"; exit 1; fi
echo "all checks passed"
