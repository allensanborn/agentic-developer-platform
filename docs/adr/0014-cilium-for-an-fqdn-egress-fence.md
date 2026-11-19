# 14. Cilium as the CNI, for an FQDN egress fence on the gateway

Status: accepted, 2026-11-19. Built (bead adp-4al); proposed and spiked 2026-11-18.

## Context

The gateway is the one pod that holds a provider key, and its NetworkPolicy allows `0.0.0.0/0` on 443 (`platform/gateway/networkpolicy.yaml`). Its only hosted backend is `openrouter.ai`. A compromised gateway can therefore reach any HTTPS service: webhook.site, which ARTEX used as C2 and exfil through 491 rotating URLs (GTIG, Nov 2026), or an LLM Mixer reselling the key. Mandiant's Layer 5 asks for exactly this egress to be restricted and its new destinations watched. Standard NetworkPolicy matches IPs, not names, and k3s's kube-router logs nothing it drops. So today the platform can neither fence by name nor see a blocked attempt, and Anthropic treats a blocked attempt as a signal in its own right.

## Decision

- Create the cluster without flannel or kube-router (`--flannel-backend=none`, `--disable-network-policy`) and install Cilium, version pinned in `versions.env`.
- Replace the gateway's `0.0.0.0/0:443` rule with a `CiliumNetworkPolicy` that allows DNS through kube-dns (with a DNS rule, so Cilium learns the answers) and `toFQDNs: openrouter.ai` on 443. Every other existing NetworkPolicy stays as it is; Cilium enforces them.
- Use Hubble's dropped-flow records as the egress-attempt signal for `adp-bio`.

## Spike, 2026-11-18

`docs/spikes/0014-cilium-egress.sh` creates a throwaway single-node k3d cluster on OrbStack with Cilium 1.20.4, then deletes it. Results:

| Test | Expected | Got |
|---|---|---|
| `https://openrouter.ai/api/v1/models`, no policy | 200 | 200 |
| same, with the FQDN policy | 200 | 200 |
| `https://webhook.site`, with the FQDN policy | blocked | 000 |
| `https://1.1.1.1`, with the FQDN policy | blocked | 000 |
| plain `NetworkPolicy` default-deny egress, under Cilium | blocked | 000 |

Hubble recorded the raw-IP attempts as `Policy denied DROPPED (TCP Flags: SYN)`. On OrbStack, the node needs `bpffs` and a shared cgroup2 mount before Cilium starts; the script does both with `docker exec`.

## Built, 2026-11-19

`k3d.yaml` creates the cluster without flannel or kube-router. `up.sh` mounts bpffs and cgroup2 in every node on every run, installs Cilium (`CILIUM_VERSION`, `platform/helm/cilium.yaml`), and refuses to run on a cluster that still has flannel. `platform/gateway/egress-fqdn.yaml` replaces the gateway's `0.0.0.0/0:443` rule. `smoke.sh` gained four checks, run from a curl pod that carries the gateway's policy label but not its Service labels:
- `openrouter.ai` returns 200;
- `webhook.site` is blocked;
- a raw IP is blocked;
- Hubble on that pod's node records `Policy denied`.

The full suite (25 checks) passed on a fresh cluster (`CLUSTER=adp-cilium`), and so did `erp-smoke.sh`, `tools-smoke.sh` and `sandbox-smoke.sh`.

**One policy had to change: the broker's route to the API server.** `sandbox/deploy/broker-api-egress.yaml` was a NetworkPolicy `ipBlock` on the API server's node IP. Cilium gives the API server its own identity (`host` on its own node, `remote-node` elsewhere), and a CIDR rule does not select it. Hubble showed `Policy denied` on `:6443`. `policyCIDRMatchMode: nodes` fixed the remote-node case only, so the rule is now a CiliumNetworkPolicy with `toEntities: [kube-apiserver]`. That also removes the IP and port templating from `sandbox-up.sh`.

**Two smoke failures were timing, not Cilium.** `sandbox-smoke.sh` read warm-pool readiness while `sandbox-up.sh` was still replacing the pods; it now waits up to 180 s. `tools-smoke.sh` once counted two log lines where it expected one, and passed on the rerun.


## Consequences

- **Existing clusters must be recreated:** `k3d cluster delete adp && scripts/up.sh`. `up.sh` detects a flannel cluster and stops with that instruction instead of installing Cilium over it.
- **The fence is only as strong as name resolution.** `toFQDNs` trusts the DNS answers kube-dns relays. A poisoned upstream resolver could point `openrouter.ai` elsewhere; TLS verification on the gateway is what catches that.
