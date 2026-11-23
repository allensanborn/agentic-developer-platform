#!/usr/bin/env bash
# Deploys the ERP discrepancy agent onto a running platform (scripts/up.sh). Idempotent.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
cd "$ROOT"

docker build -q -t adp/erp:dev erp/app
docker build -q --build-arg "UPGRADE_EPOCH=$(date -u +%F)" -t adp/chinook:dev erp/db # adp-ehy
k3d image import -c "$CLUSTER" adp/erp:dev adp/chinook:dev

# Onboarding this tenant is two platform edits: reach the state store, and be allow-listed for models.
kubectl apply -f platform/aws/floci.yaml -f platform/gateway/models.yaml

aws() { scripts/aws.sh "$@" </dev/null; }
aws dynamodb describe-table --table-name erp-workflow-state >/dev/null 2>&1 ||
  aws dynamodb create-table --table-name erp-workflow-state --billing-mode PAY_PER_REQUEST \
    --attribute-definitions AttributeName=key,AttributeType=S \
    --key-schema AttributeName=key,KeyType=HASH --query TableDescription.TableName --output text
# Database passwords are generated here, sent on stdin, and never printed or stored locally.
aws secretsmanager describe-secret --secret-id adp/erp/db >/dev/null 2>&1 ||
  printf '{"superuser":"%s","executor":"%s","reader":"%s"}' \
    "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" "$(openssl rand -hex 24)" |
  scripts/aws.sh secretsmanager create-secret --name adp/erp/db \
    --secret-string file:///dev/stdin --query Name --output text

kubectl apply -k erp/deploy
kubectl wait -n erp externalsecret/erp-db --for=condition=Ready --timeout=2m
for d in chinook erp-executor erp-agent erp-controller; do
  kubectl rollout restart -n erp "deploy/$d" >/dev/null # pick up rebuilt images
  kubectl rollout status -n erp "deploy/$d" --timeout=5m
done
