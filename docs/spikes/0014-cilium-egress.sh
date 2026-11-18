#!/usr/bin/env bash
# Throwaway spike for adp-4al: does Cilium on k3d (OrbStack) give an FQDN egress fence + drop logs,
# and still enforce plain NetworkPolicy? Creates and always deletes cluster adp-egress-spike.
set -uo pipefail
C=adp-egress-spike
D="$(cd "$(dirname "$0")/../.." && pwd)/.scratch/egress-spike"; mkdir -p "$D"
export KUBECONFIG="$D/kubeconfig"
CURL=curlimages/curl:8.21.0@sha256:7c12af72ceb38b7432ab85e1a265cff6ae58e06f95539d539b654f2cfa64bb13
trap 'k3d cluster delete "$C" >/dev/null 2>&1; echo "cluster $C deleted"' EXIT
step() { echo; echo "### $*"; }

step create
k3d cluster create "$C" --servers 1 --agents 0 --no-lb --image rancher/k3s:v1.35.10-k3s1 \
  --k3s-arg '--flannel-backend=none@server:*' --k3s-arg '--disable-network-policy@server:*' \
  --k3s-arg '--disable=traefik@server:*' \
  --kubeconfig-update-default=false --kubeconfig-switch-context=false --wait || exit 1
k3d kubeconfig get "$C" >"$KUBECONFIG"
for n in $(docker ps --format '{{.Names}}' | grep "^k3d-$C-server"); do
  docker exec "$n" sh -c 'mount bpffs /sys/fs/bpf -t bpf && mount --make-shared /sys/fs/bpf; mkdir -p /run/cilium/cgroupv2 && mount -t cgroup2 none /run/cilium/cgroupv2 && mount --make-shared /run/cilium/cgroupv2' || echo "mount step failed on $n"
done

step cilium
helm install cilium cilium/cilium --version 1.20.4 -n kube-system \
  --set operator.replicas=1 --set ipam.mode=kubernetes --set hubble.relay.enabled=false \
  --wait --timeout 10m || { kubectl -n kube-system get pods; kubectl -n kube-system logs ds/cilium --tail=40; exit 1; }
kubectl wait --for=condition=Ready node --all --timeout=180s
kubectl -n kube-system rollout status deploy/coredns --timeout=180s

probe() { # ns
  kubectl create ns "$1" >/dev/null
  kubectl -n "$1" run c --image "$CURL" --restart=Never --command -- sleep 900 >/dev/null
  kubectl -n "$1" wait pod/c --for=condition=Ready --timeout=120s >/dev/null
}
code() { kubectl -n "$1" exec c -- curl -s -m 8 -o /dev/null -w '%{http_code}' "$2" 2>/dev/null | tail -c 3; }

step "baseline (no policy)"
probe t
echo "openrouter: $(code t https://openrouter.ai/api/v1/models)  webhook.site: $(code t https://webhook.site)"

step "FQDN policy: DNS to kube-dns + openrouter.ai:443 only"
kubectl apply -f - <<'YAML'
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata: {name: provider-egress, namespace: t}
spec:
  endpointSelector: {}
  egress:
    - toEndpoints:
        - matchLabels: {"k8s:io.kubernetes.pod.namespace": kube-system, "k8s:k8s-app": kube-dns}
      toPorts:
        - ports: [{port: "53", protocol: ANY}]
          rules: {dns: [{matchPattern: "*"}]}
    - toFQDNs: [{matchName: openrouter.ai}]
      toPorts: [{ports: [{port: "443", protocol: TCP}]}]
YAML
sleep 5
echo "openrouter (want 200): $(code t https://openrouter.ai/api/v1/models)"
echo "webhook.site (want 000): $(code t https://webhook.site)"
echo "raw IP 1.1.1.1 (want 000): $(code t https://1.1.1.1)"

step "hubble: dropped flows from ns t"
kubectl -n kube-system exec ds/cilium -c cilium-agent -- hubble observe --namespace t --verdict DROPPED --last 10 -o compact 2>&1 | tail -10

step "plain NetworkPolicy still enforced (default-deny egress in ns u)"
probe u
kubectl apply -f - <<'YAML'
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata: {name: deny, namespace: u}
spec: {podSelector: {}, policyTypes: [Egress]}
YAML
sleep 5
echo "openrouter from u (want 000): $(code u https://openrouter.ai/api/v1/models)"
