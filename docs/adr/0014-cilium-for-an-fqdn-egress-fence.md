# 14. Cilium as the CNI, for an FQDN egress fence on the gateway

Status: proposed, 2026-11-18. Spiked (below); not built. Bead adp-4al.

## Context

The gateway is the one pod that holds a provider key, and its NetworkPolicy allows `0.0.0.0/0` on 443 (`platform/gateway/networkpolicy.yaml`). Its only hosted backend is `openrouter.ai`. A compromised gateway can therefore reach any HTTPS service: webhook.site, which ARTEX used as C2 and exfil through 491 rotating URLs (GTIG, Nov 2026), or an LLM Mixer reselling the key. Mandiant's Layer 5 asks for exactly this egress to be restricted and its new destinations watched. Standard NetworkPolicy matches IPs, not names, and k3s's kube-router logs nothing it drops. So today the platform can neither fence by name nor see a blocked attempt, and Anthropic treats a blocked attempt as a signal in its own right.

## Decision (proposed)

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

## Consequences

- **Existing clusters are not migrated.** `up.sh` skips creation when the cluster exists, so this lands only on a recreated cluster.
- **The full platform hasn't run on Cilium.** Only the five checks above have. Dapr, agentgateway, External Secrets and the smoke suite still need a run.
- **The fence is only as strong as name resolution.** `toFQDNs` trusts the DNS answers kube-dns relays. A poisoned upstream resolver could point `openrouter.ai` elsewhere; TLS verification on the gateway is what catches that.
