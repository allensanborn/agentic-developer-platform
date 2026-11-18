#!/usr/bin/env bash
# The sandbox stage (workshop lab 5): gVisor on the agent node, the agent-sandbox control
# plane, a warm pool of air-gapped sandboxes, and the code-execution broker behind the
# gateway. Opt-in, after scripts/up.sh and scripts/tools-up.sh; safe to re-run.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
cd "$ROOT"

GVISOR_RELEASE=20261116
AGENT_SANDBOX_VERSION=v0.5.0
CONTROLLER_IMAGE=registry.k8s.io/agent-sandbox/agent-sandbox-controller:v0.5.0@sha256:e99cac42f10cac69cab09a91e59f982c9d525b2933a5f5b7dfd52dae09340aa2
# Renovate bumps CONTROLLER_IMAGE alone; the release manifests and their checksums below must
# move with it, so a partial bump stops here instead of running a controller against older CRDs.
case "$CONTROLLER_IMAGE" in *":$AGENT_SANDBOX_VERSION@"*) ;; *)
  echo "CONTROLLER_IMAGE is not $AGENT_SANDBOX_VERSION: bump AGENT_SANDBOX_VERSION and the manifest checksums with it" >&2
  exit 1 ;;
esac
node="k3d-$CLUSTER-agent-0"
cache="$ROOT/.scratch/sandbox" # gitignored download cache
mkdir -p "$cache"

# --- gVisor on the agent node. k3d nodes are containers, so this does not survive a cluster
# delete; re-run after one. Pinned release, checked against its published sha512.
arch=$(docker exec "$node" uname -m)
case "$arch" in
  aarch64) sha512=a64ce2d5ba6825a0a6459ee6a9ce40164749c2d276a945b885673988c4e545e66b2f4ef3a08e068a26cca676061c8c5e8ba982156feb786f0eab995f5b8b854d ;;
  x86_64) sha512=c87d792d5842efb70c38ee822124cfe0821a547715e7abcf3f2b14997cd02784edaa0b91e238ec5c27a25a1b9e00bf98113398eb62a0778d8d20d4e222f8b0e0 ;;
  *) echo "no pinned gVisor checksum for $arch" >&2; exit 1 ;;
esac
tarball="$cache/gvisor-$GVISOR_RELEASE-$arch.tar.bz2"
[ -f "$tarball" ] || curl -fsSL -o "$tarball" \
  "https://storage.googleapis.com/gvisor/releases/release/$GVISOR_RELEASE/$arch/gvisor.tar.bz2"
echo "$sha512  $tarball" | shasum -a 512 -c --status || { rm -f "$tarball"; echo "gVisor checksum mismatch" >&2; exit 1; }
rm -rf "$cache/gvisor" && mkdir -p "$cache/gvisor" && tar -xjf "$tarball" -C "$cache/gvisor"

# runsc needs gvisor-bin/ beside it (its sentry and gofers). oci-seccomp makes runsc enforce
# the pod's seccomp profile inside the sandbox; without it RuntimeDefault passes admission
# and is ignored.
conf=/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/gvisor.toml
want='[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc]
  runtime_type = "io.containerd.runsc.v1"
[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runsc.options]
  TypeUrl = "io.containerd.runsc.v1.options"
  ConfigPath = "/etc/runsc.toml"'
have=$(docker exec "$node" cat "$conf" 2>/dev/null || true)
docker cp "$cache/gvisor/." "$node:/bin/"
printf '[runsc_config]\n  oci-seccomp = "true"\n' | docker exec -i "$node" sh -c 'cat > /etc/runsc.toml'
if [ "$have" != "$want" ]; then
  docker exec -i "$node" sh -c "mkdir -p $(dirname "$conf") && cat > $conf" <<<"$want"
  docker restart "$node" >/dev/null # containerd reads runtimes at start
  kubectl wait --for=condition=Ready "node/$node" --timeout=180s
fi
kubectl label node "$node" adp.dev/gvisor=true --overwrite >/dev/null

# --- agent-sandbox control plane: upstream's release manifests, checked by sha256, the
# controller image pinned by digest, then made Pod Security `restricted` (it writes its webhook
# certificates under /tmp, hence the emptyDir under a read-only root).
for f in manifest:ccfe3649de8b33f0ee0ec635e2c7b40e1c468ad9fde6aac7c7379501327d9c4c \
         extensions:a6dd82905f3f3a44d30d02e283b6eb10d22c5fc1455604cf905d0e76091686d1; do
  file="$cache/agent-sandbox-$AGENT_SANDBOX_VERSION-${f%%:*}.yaml"
  [ -f "$file" ] || curl -fsSL -o "$file" \
    "https://github.com/kubernetes-sigs/agent-sandbox/releases/download/$AGENT_SANDBOX_VERSION/${f%%:*}.yaml"
  echo "${f#*:}  $file" | shasum -a 256 -c --status || { rm -f "$file"; echo "$file: checksum mismatch" >&2; exit 1; }
  sed "s|image: registry.k8s.io/agent-sandbox/agent-sandbox-controller:[^ ]*|image: $CONTROLLER_IMAGE|" "$file" |
    kubectl apply --server-side -f - >/dev/null
done
kubectl patch -n agent-sandbox-system deploy/agent-sandbox-controller --type=strategic -p '{"spec":{"template":{"spec":{
  "automountServiceAccountToken":true,
  "securityContext":{"runAsNonRoot":true,"runAsUser":65532,"seccompProfile":{"type":"RuntimeDefault"}},
  "volumes":[{"name":"tmp","emptyDir":{}}],
  "containers":[{"name":"agent-sandbox-controller",
    "volumeMounts":[{"name":"tmp","mountPath":"/tmp"}],
    "securityContext":{"allowPrivilegeEscalation":false,"readOnlyRootFilesystem":true,"capabilities":{"drop":["ALL"]}}}]}}}}' >/dev/null
kubectl label namespace agent-sandbox-system pod-security.kubernetes.io/enforce=restricted --overwrite >/dev/null
kubectl rollout status -n agent-sandbox-system deploy/agent-sandbox-controller --timeout=5m
kubectl wait --for=condition=Established --timeout=2m crd/sandboxtemplates.extensions.agents.x-k8s.io \
  crd/sandboxwarmpools.extensions.agents.x-k8s.io crd/sandboxclaims.extensions.agents.x-k8s.io

# --- the sandbox runtime and the broker.
docker build -q -t adp/python-sandbox:dev sandbox/runtime
docker build -q -t adp/code-executor:dev sandbox/broker
k3d image import -c "$CLUSTER" adp/python-sandbox:dev adp/code-executor:dev

# The broker queries orders by fiscal quarter on a `period-index` GSI, and needs every
# order's attributes; tools-up.sh's table has neither. ponytail: create-if-missing, and the
# seed is skipped once the last order is present.
aws() { scripts/aws.sh "$@"; }
aws dynamodb describe-table --table-name adp-orders --query 'Table.GlobalSecondaryIndexes[].IndexName' \
  --output text </dev/null | grep -q period-index ||
  aws dynamodb update-table --table-name adp-orders \
    --attribute-definitions AttributeName=period,AttributeType=S \
    --global-secondary-index-updates '[{"Create":{"IndexName":"period-index","KeySchema":[{"AttributeName":"period","KeyType":"HASH"}],"Projection":{"ProjectionType":"ALL"}}}]' \
    --query Table.TableName --output text </dev/null
if ! aws dynamodb get-item --table-name adp-orders --key '{"order_id":{"S":"ORD-1500"}}' \
  --query Item.period.S --output text </dev/null | grep -q Q; then
  while read -r batch; do
    aws dynamodb batch-write-item --request-items file:///dev/stdin --output text <<<"$batch" >/dev/null
  done <sandbox/seed-orders.json
fi

kubectl apply -k sandbox/deploy >/dev/null
api=$(kubectl get endpoints kubernetes -n default -o jsonpath='{.subsets[0].addresses[0].ip} {.subsets[0].ports[0].port}')
sed "s|__API_IP__|${api% *}|; s|__API_PORT__|${api#* }|" sandbox/deploy/broker-api-egress.yaml | kubectl apply -f - >/dev/null
kubectl rollout status -n agent-sandbox-system deploy/sandbox-router-deployment --timeout=5m
kubectl rollout restart -n tools deploy/code-executor >/dev/null # pick up a rebuilt image
kubectl rollout status -n tools deploy/code-executor --timeout=3m
# The warm pool's pods are pinned to the image they started with; recycle them after a build.
kubectl delete pod -n agent-sandbox -l sandbox-kind=python --ignore-not-found >/dev/null
echo "sandbox up. Check with scripts/sandbox-smoke.sh"
