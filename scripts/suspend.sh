#!/usr/bin/env bash
# Cut one identity off from outside the agent (ADR 0022), and give it back.
#
#   scripts/suspend.sh on <namespace>/<serviceaccount>   gateway 403, then no egress at all
#   scripts/suspend.sh off <namespace>/<serviceaccount>  undo both
#   scripts/suspend.sh list                              who is suspended
#
# Gateway first: one Require rule on the whole Gateway (both listeners), evaluated with every
# model's and tool's own allow-list, so the identity gets 403 everywhere. Then a Cilium policy
# denies all egress from that ServiceAccount's pods, for a workload that ignores the 403.
# Nothing is deleted or scaled. A run that calls the gateway while suspended fails, since a 403
# is final to the agent; its workflow state stays in the store.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"

POLICY=suspended # AgentgatewayPolicy in ai-gateway; the identities are its annotation
ANN=adp.dev/suspended

suspended() { kubectl get agentgatewaypolicy -n ai-gateway "$POLICY" -o jsonpath="{.metadata.annotations.adp\.dev/suspended}" 2>/dev/null || true; }

gateway() { # space-separated ns/sa list: write the rule, or remove it when empty
  if [ -z "$1" ]; then kubectl delete agentgatewaypolicy -n ai-gateway "$POLICY" --ignore-not-found >/dev/null; return; fi
  subs=$(for id in $1; do printf '"system:serviceaccount:%s:%s",' "${id%/*}" "${id#*/}"; done)
  kubectl apply -f - >/dev/null <<EOF
apiVersion: agentgateway.dev/v1alpha1
kind: AgentgatewayPolicy
metadata:
  name: $POLICY
  namespace: ai-gateway
  annotations:
    $ANN: "$1"
spec:
  targetRefs:
    - group: gateway.networking.k8s.io
      kind: Gateway
      name: ai-gateway
  traffic:
    authorization:
      action: Require # fails closed: an expression error denies
      policy:
        matchExpressions:
          - '!(jwt.sub in [${subs%,}])'
EOF
  kubectl wait -n ai-gateway "agentgatewaypolicy/$POLICY" --for=jsonpath='{.status.ancestors[0].conditions[?(@.type=="Attached")].status}'=True --timeout=30s >/dev/null
}

case "${1:-}" in
  on | off)
    id=${2:?usage: $0 on|off <namespace>/<serviceaccount>}
    [[ "$id" == */* ]] || { echo "identity is <namespace>/<serviceaccount>" >&2; exit 2; }
    ns=${id%/*} sa=${id#*/}
    others=$(for s in $(suspended); do [ "$s" = "$id" ] || printf '%s ' "$s"; done)
    if [ "$1" = on ]; then
      gateway "$others$id"
      echo "gateway: $id gets 403 on every model and tool"
      kubectl apply -f - >/dev/null <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: suspended-$sa
  namespace: $ns
  labels:
    $ANN: "true"
spec:
  endpointSelector:
    matchLabels:
      io.cilium.k8s.policy.serviceaccount: $sa
  egressDeny:
    - toEntities: [all]
EOF
      echo "network: pods running as $id have no egress"
      kubectl get pods -n "$ns" --field-selector=status.phase=Running \
        -o jsonpath="{range .items[?(@.spec.serviceAccountName==\"$sa\")]}still running, cut off: {.metadata.name}{'\n'}{end}"
    else
      kubectl delete ciliumnetworkpolicy -n "$ns" "suspended-$sa" --ignore-not-found >/dev/null
      gateway "${others% }"
      echo "resumed: $id"
    fi
    ;;
  list) for s in $(suspended); do echo "$s"; done ;;
  *) echo "usage: $0 on|off <namespace>/<serviceaccount> | list" >&2; exit 2 ;;
esac
