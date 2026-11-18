#!/usr/bin/env bash
# The tools stage (workshop labs 3-4): the orders MCP server behind the gateway with
# per-tool authorization. Opt-in, after scripts/up.sh; safe to re-run.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
cd "$ROOT"

docker build -q -t adp/orders-mcp:dev tools/orders-mcp
k3d image import -c "$CLUSTER" adp/orders-mcp:dev

# The orders table. ponytail: imperative and create-if-missing, like up.sh's.
aws() { scripts/aws.sh "$@"; }
aws dynamodb describe-table --table-name adp-orders >/dev/null 2>&1 </dev/null ||
  aws dynamodb create-table --table-name adp-orders --billing-mode PAY_PER_REQUEST \
    --attribute-definitions AttributeName=order_id,AttributeType=S \
    --key-schema AttributeName=order_id,KeyType=HASH --query TableDescription.TableName --output text </dev/null
aws dynamodb batch-write-item --request-items file:///dev/stdin --output text <tools/orders-mcp/seed.json >/dev/null

kubectl apply -k tools/deploy
kubectl rollout status -n tools deploy/orders-mcp --timeout=3m
kubectl rollout restart -n tools deploy/orders-mcp # pick up a rebuilt image
kubectl rollout status -n tools deploy/orders-mcp --timeout=3m
echo "tools up. Check with scripts/tools-smoke.sh"
