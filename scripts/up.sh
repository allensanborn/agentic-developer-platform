#!/usr/bin/env bash
# Bring the whole platform up. Idempotent: safe to re-run after any change.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
cd "$ROOT"

k3d cluster list "$CLUSTER" >/dev/null 2>&1 ||
  k3d cluster create "$CLUSTER" --config k3d.yaml --image "$K3S_IMAGE" --wait
k3d kubeconfig get "$CLUSTER" > "$KUBECONFIG"
chmod 600 "$KUBECONFIG"

h() { helm upgrade --install --wait --timeout 5m "$@"; }

# CRDs before the control planes that watch them.
kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$GATEWAY_API_VERSION/standard-install.yaml"
h agentgateway-crds oci://ghcr.io/agentgateway/charts/agentgateway-crds \
  --version "$AGENTGATEWAY_VERSION" -n agentgateway-system --create-namespace
h agentgateway oci://ghcr.io/agentgateway/charts/agentgateway \
  --version "$AGENTGATEWAY_VERSION" -n agentgateway-system
h external-secrets oci://ghcr.io/external-secrets/charts/external-secrets \
  --version "$EXTERNAL_SECRETS_VERSION" -n external-secrets --create-namespace \
  -f platform/helm/external-secrets.yaml
h dapr dapr --repo https://dapr.github.io/helm-charts --version "$DAPR_VERSION" \
  -n dapr-system --create-namespace -f platform/helm/dapr.yaml

docker build -q -t adp/research-agent:dev agent
k3d image import -c "$CLUSTER" adp/research-agent:dev

kubectl apply -f platform/namespaces.yaml
kubectl apply -k platform
# Caller identity: the gateway verifies ServiceAccount tokens against the API server's
# signing keys. ponytail: a snapshot, re-run after a signing-key rotation; a remote JWKS
# reference to the API server removes the step (tracked in beads).
sed "s|__CLUSTER_JWKS__|$(kubectl get --raw /openid/v1/jwks)|" platform/gateway/caller-identity.yaml |
  kubectl apply -f -

# AWS resources. ponytail: imperative and create-if-missing; the production form is a
# Terraform root applied unchanged to floci and AWS (tracked in beads).
kubectl rollout status -n aws deploy/floci --timeout=5m
aws() { scripts/aws.sh "$@" </dev/null; }
aws secretsmanager describe-secret --secret-id adp/providers/openrouter >/dev/null 2>&1 ||
  aws secretsmanager create-secret --name adp/providers/openrouter \
    --secret-string unset --query Name --output text
aws dynamodb describe-table --table-name adp-agent-state >/dev/null 2>&1 ||
  aws dynamodb create-table --table-name adp-agent-state --billing-mode PAY_PER_REQUEST \
    --attribute-definitions AttributeName=key,AttributeType=S \
    --key-schema AttributeName=key,KeyType=HASH --query TableDescription.TableName --output text

kubectl rollout status -n ai-gateway deploy/ai-gateway --timeout=5m
kubectl rollout status -n models deploy/ollama --timeout=20m
kubectl rollout restart -n agents deploy/research-agent # pick up a rebuilt image
kubectl rollout status -n agents deploy/research-agent --timeout=5m
echo "up. Set a provider key with scripts/provider-key.sh openrouter; check with scripts/smoke.sh"
