#!/usr/bin/env bash
# Run one AWS CLI command against the platform's AWS (floci) from a short-lived pod.
# stdin is passed through, so secret values can be piped in and never appear in argv.
#   scripts/aws.sh dynamodb list-tables
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"

args=$(printf '%s\n' "$@" | jq -R . | jq -cs .)
kubectl run "aws-admin-$RANDOM" -n aws --rm -i --quiet --restart=Never \
  --labels app=aws-admin \
  --image amazon/aws-cli:2.40.0@sha256:0da258e32b17cc468b2e8812c8d93f5732561b901357c43a207baae0567b195a \
  --overrides "$(jq -cn --argjson args "$args" '{spec: {
    automountServiceAccountToken: false,
    securityContext: {runAsNonRoot: true, runAsUser: 10001, seccompProfile: {type: "RuntimeDefault"}},
    containers: [{
      name: "aws", stdin: true, stdinOnce: true,
      # A new pod can start before its NetworkPolicy allowance is programmed; wait for
      # the endpoint so the first call does not fail on a race.
      command: ["/bin/sh", "-c",
        "for i in $(seq 30); do aws sts get-caller-identity >/dev/null 2>&1 && break; sleep 1; done; exec aws \"$@\"", "--"],
      args: $args,
      image: "amazon/aws-cli:2.40.0@sha256:0da258e32b17cc468b2e8812c8d93f5732561b901357c43a207baae0567b195a",
      env: [
        {name: "AWS_ENDPOINT_URL", value: "http://floci.aws.svc.cluster.local:4566"},
        {name: "AWS_REGION", value: "us-east-1"},
        {name: "AWS_ACCESS_KEY_ID", value: "test"},
        {name: "AWS_SECRET_ACCESS_KEY", value: "test"},
        {name: "HOME", value: "/tmp"}
      ],
      securityContext: {allowPrivilegeEscalation: false, capabilities: {drop: ["ALL"]}}
    }]}}')"
