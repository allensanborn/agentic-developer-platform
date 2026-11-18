#!/usr/bin/env bash
# End-to-end check of what the ERP discrepancy agent claims, against the live cluster:
# a fix is applied only after a named approver approves that exact proposal, and nothing
# but the executor can change the data.
#
# The agent diagnoses with the `scripted` alias by default: one fixed answer, so these
# mechanics are checked without a real model (adp-ctc). ERP_SMOKE_ALIAS=smart runs the same
# checks against a real model.
set -uo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"

RULE=invoice_total_mismatch
EP=$(date +%s) # a fresh episode per smoke run, so reruns never collide with old runs
ALIAS=${ERP_SMOKE_ALIAS:-"scripted"}
fails=0

agent_alias() { # alias, or "-" to restore the default
  if [ "$1" = - ]; then set -- DIAGNOSIS_ALIAS-; else set -- "DIAGNOSIS_ALIAS=$1"; fi
  kubectl set env -n erp deploy/erp-agent -c app "$1" >/dev/null
  kubectl rollout status -n erp deploy/erp-agent --timeout=3m >/dev/null
}
trap 'agent_alias -' EXIT
agent_alias "$ALIAS"
echo "diagnosing with alias: $ALIAS"

check() { # description, expected, actual
  if [ "$2" = "$3" ]; then echo "PASS  $1"; else echo "FAIL  $1 (expected $2, got $3)"; fails=$((fails + 1)); fi
}
sql() { kubectl exec -n erp deploy/chinook -- psql -U postgres -d chinook -tAc "$1"; }
cli() { kubectl exec -n erp deploy/erp-controller -c app -- python cli.py "$@" 2>/dev/null; }
seed() { sql "UPDATE invoice SET total = (SELECT SUM(unit_price * quantity) FROM invoice_line WHERE invoice_id = $1) + 5 WHERE invoice_id = $1" >/dev/null; }
is_open() { sql "SELECT count(*) FROM detect.$RULE WHERE key = $1"; }
await() { # run, jq filter that becomes non-empty: prints it, or nothing after 90s
  for _ in $(seq 1 45); do
    out=$(cli show "$1" | jq -r "$2 // empty")
    if [ -n "$out" ]; then echo "$out"; return; fi
    sleep 2
  done
}
reach() { # deployment: can its app container open a connection to the database?
  kubectl exec -n erp "deploy/$1" -c app -- python -c \
    "import socket; socket.create_connection(('chinook.erp.svc.cluster.local', 5432), 4)" >/dev/null 2>&1 && echo yes || echo no
}

echo "== approval"
seed 7
cli start $RULE 7 "$EP" >/dev/null
run=$RULE-7-$EP
hash=$(await "$run" .awaiting.hash)
check "a proposed fix that passes the check waits for an approver" approvers "$(cli show "$run" | jq -r .awaiting.awaiting)"
cli decide "$run" not-this-proposal approve alice >/dev/null
cli decide "$run" "$hash" approve "" >/dev/null
sleep 6
check "approving a different proposal, or as nobody, changes nothing" "RUNNING 1" "$(cli show "$run" | jq -r .status) $(is_open 7)"
cli decide "$run" "$hash" approve smoke-approver >/dev/null
check "a named approver's approval of that proposal commits it" committed "$(await "$run" .result.outcome)"
check "the discrepancy is gone" 0 "$(is_open 7)"
check "the audit row names the approver" smoke-approver "$(sql "SELECT approver FROM fix.audit WHERE proposal_hash = '$hash'")"

seed 9
cli start $RULE 9 "$EP" >/dev/null
run=$RULE-9-$EP
hash=$(await "$run" .awaiting.hash)
cli decide "$run" "$hash" reject smoke-approver >/dev/null
check "a rejection ends the run and applies nothing" "rejected 1" "$(await "$run" .result.outcome) $(is_open 9)"

seed 11
cli start $RULE 11 "$EP" >/dev/null
run=$RULE-11-$EP
await "$run" .awaiting.hash >/dev/null
sql "UPDATE invoice SET total = total - 5 WHERE invoice_id = 11" >/dev/null # someone fixes it by hand
cli resolved $RULE 11 "$EP" >/dev/null
check "a discrepancy fixed by other means ends the run without a commit" resolved_elsewhere "$(await "$run" .result.outcome)"

echo "== isolation"
check "the executor can reach the database" yes "$(reach erp-executor)"
check "the controller cannot reach the database" no "$(reach erp-controller)"

# A hijacked agent: replace the agent's code with a workflow that calls the executor's
# commit directly, under the agent's own identity. Invoice 9 is still open from above.
rogue='
import time, dapr.ext.workflow as wf
rt = wf.WorkflowRuntime()
def rogue(ctx, _):
    r = yield ctx.call_activity("commit", app_id="erp-executor", input={"rule": "invoice_total_mismatch", "key": 9,
        "fix_type": "set_invoice_total_from_lines", "params": {}, "hash": "rogue", "approver": "mallory"})
    return r
rt.register_workflow(rogue, name="rogue"); rt.start(); time.sleep(8)
wf.DaprWorkflowClient().schedule_new_workflow("rogue", instance_id="rogue-'"$EP"'")
print("ROGUE SCHEDULED", flush=True); time.sleep(3600)'
kubectl patch -n erp deploy/erp-agent --type=json \
  -p "$(jq -nc --arg s "$rogue" '[{op:"replace",path:"/spec/template/spec/containers/0/args",value:["-c",$s]}]')" >/dev/null
kubectl rollout status -n erp deploy/erp-agent --timeout=3m >/dev/null
for _ in $(seq 1 30); do kubectl logs -n erp deploy/erp-agent -c app 2>/dev/null | grep -q "ROGUE SCHEDULED" && break; sleep 2; done
scheduled=$(kubectl logs -n erp deploy/erp-agent -c app 2>/dev/null | grep -c "ROGUE SCHEDULED")
sleep 20
check "a hijacked agent's direct call to commit is refused" "1 0 1" "$scheduled $(sql "SELECT count(*) FROM fix.audit WHERE proposal_hash = 'rogue'") $(is_open 9)"
kubectl rollout undo -n erp deploy/erp-agent >/dev/null
kubectl rollout status -n erp deploy/erp-agent --timeout=3m >/dev/null
sql "UPDATE invoice SET total = total - 5 WHERE invoice_id = 9" >/dev/null # leave the data clean

echo
if [ "$fails" -eq 0 ]; then echo "all checks passed"; else echo "$fails check(s) failed"; exit 1; fi
