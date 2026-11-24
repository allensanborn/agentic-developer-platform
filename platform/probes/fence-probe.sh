#!/bin/sh
# The fence probe (ADR 0021): each fence that fails open, tested by a deny and an allow beside
# it, so a broken probe cannot read as a working fence. Run every 5 minutes by the CronJob in
# fence-probe.yaml, and once by scripts/smoke.sh. Reports fence_probe_ok{fence} (1 or 0) over
# OTLP; alerts.yml fires on a 0 and on no report for 15 minutes. Exits 1 if any fence fails.
GW=http://ai-gateway.ai-gateway.svc.cluster.local:8080
OTLP=http://lgtm.telemetry.svc.cluster.local:4318
token=$(cat /var/run/secrets/ai-gateway/token)
other=$(cat /var/run/secrets/other-audience/token)
code() { curl -s -m 8 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null | tail -c 3; }
chat() { # alias
  code -m 60 "$GW/v1/chat/completions" -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
    -d '{"model":"'"$1"'","max_tokens":1,"messages":[{"role":"user","content":"hi"}]}'
}
failed=""
check() { # fence, description, expected, actual
  if [ "$3" = "$4" ]; then echo "PASS  $1: $2"; else echo "FAIL  $1: $2 (expected $3, got $4)"; failed="$failed $1"; fi
}

check identity "no token is rejected" 401 "$(code "$GW/v1/models")"
check identity "a token for another audience is rejected" 401 "$(code -H "Authorization: Bearer $other" "$GW/v1/models")"
check identity "the probe's own token is accepted" 200 "$(code -H "Authorization: Bearer $token" "$GW/v1/models")"
check entitlement "the probe may call fast" 200 "$(chat fast)"
check entitlement "the probe may not call smart" 403 "$(chat smart)"
check egress "a local model cannot be reached directly" 000 "$(code http://ollama.models.svc.cluster.local:11434/api/tags)"
check egress "the host's model cannot be reached directly" 000 "$(code http://host.docker.internal:11434/api/version)"
check egress "the internet cannot be reached" 000 "$(code https://openrouter.ai)"

now=$(date +%s)000000000
points=""
for fence in identity entitlement egress; do
  case " $failed " in *" $fence "*) ok=0 ;; *) ok=1 ;; esac
  points="$points{\"asInt\":\"$ok\",\"timeUnixNano\":\"$now\",\"attributes\":[{\"key\":\"fence\",\"value\":{\"stringValue\":\"$fence\"}}]},"
done
sent=$(code -X POST "$OTLP/v1/metrics" -H 'Content-Type: application/json' -d '{"resourceMetrics":[{"resource":{"attributes":[{"key":"service.name","value":{"stringValue":"fence-probe"}}]},"scopeMetrics":[{"metrics":[{"name":"fence_probe_ok","gauge":{"dataPoints":['"${points%,}"']}}]}]}]}')
[ "$sent" = 200 ] || echo "FAIL  report: OTLP returned $sent"
[ -z "$failed" ] && [ "$sent" = 200 ]
