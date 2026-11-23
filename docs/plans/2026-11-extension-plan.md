# Extension plan: supervised runs, then delivery

Status: draft for review, 2026-11-23. Reviewed at `fda2f70`; the commits on `main` since then change policy and licence files only. Nothing here is built.

## Bottom line

The platform controls **who** an agent is and **what that identity may reach**. It does not yet control **one run**: a run has no scope of its own, the fences are proven at deploy time and not again, nobody has rehearsed stopping one agent, and the evidence an approver reads comes from the agent. Phase 1 closes those four gaps with four small changes (ADRs 0020 to 0023). The phases after it are the existing backlog, put in an order.

Three decisions are yours and block parts of the plan. They are listed under "Decisions for you" at the end.

## Where the gaps come from

Two inputs.

**The repository's own record.** 33 open beads and the 13 open risks in `docs/threat-model.md`. Work paused on 2026-11-19 at the gateway TLS decision (`adp-vbi`).

**OpenAI's reference architecture for supervised security investigations** ([PDF](https://cdn.openai.com/pdf/49112a33-7dc9-4fa7-89ea-095a57552ed2/supervised-investigations-with-daybreak-red-a-reference-architecture.pdf), 2026-11-09). It is a vendor deployment guide for a cyber model, with no measurements, but its controls are product-independent. Mapped to this platform:

| Control in the guide | Here today | Gap |
|---|---|---|
| A scope per run: target, permitted actions, window, stop condition | Allow-lists per identity. ADR 0009 binds one approval to one proposal | A run inherits everything its ServiceAccount may do. The token budget is per identity over a window, not per run |
| A network allowlist inside the agent, plus rules the agent cannot change | Default-deny NetworkPolicy and the Cilium FQDN fence (ADR 0014) | None. The fence is already outside the agent |
| A preflight before work starts: one allowed and one forbidden attempt per fence, checked in independent logs | The same rule ("every deny check keeps an allow check beside it"), run by `smoke.sh` when someone runs it | Nothing re-proves a fence after deploy. No CronJob exists under `platform/` |
| A separate reviewer for in-scope sensitive actions; a human for a change of scope | A named human for ERP commits (ADR 0009); a prompt-guard tripwire | No tier between "allowed" and "needs a named human" |
| Telemetry the agent account cannot change or delete | otel-lgtm in its own namespace, query by port-forward only (ADR 0017) | One node, the image's default retention for logs and traces, no immutability |
| A stop the operator controls from outside the agent, verified before the first run | Budgets return 429. A policy can be edited by hand | No rehearsed way to suspend one identity |

## Phase 0: finish what is paused

The three P1 beads that the rest depends on. No new design.

| Work | Bead | Proof |
|---|---|---|
| TLS on the gateway listener. The bead's notes rule out Dapr mTLS for this hop. The smallest change is cert-manager and an HTTPS listener | `adp-vbi` | smoke: plain HTTP is refused, beside an HTTPS call that succeeds |
| Run the hosted path with a real key | `adp-8ms` | smoke: `smart` is answered by the hosted model, and a revoked key raises an alert instead of a silent fallback |
| Eval gate (ADR 0011) | `adp-5gs` | `dagger call check` fails on a seeded prompt regression |

Phase 1 does not wait for TLS. It does wait for nothing else.

## Phase 1: supervised runs

Ordered smallest first. Each item is one ADR and one or two smoke checks.

| # | Change | ADR | Size (guess) | Proof |
|---|---|---|---|---|
| 1 | Suspend one identity with one command, from outside the agent | 0022 | small | smoke: a suspended identity gets 403 and loses egress while a second identity still works; resume restores it |
| 2 | Fence probes run on a schedule and export a result; a stale or failed probe alerts | 0021 | small | `promtool`: the alert fires on a stale probe; smoke: breaking one policy turns the probe red within one interval |
| 3 | An approver's evidence is built from the gateway's record, and that record outlives the pod | 0023 | medium | erp-smoke: a run whose agent reports a tool call the gateway never saw is flagged before approval |
| 4 | A run carries a scope the gateway enforces: tools, aliases, token ceiling, deadline | 0020 | large: needs a token issuer | smoke: a call outside the run's scope is refused for an identity that is otherwise allowed it |

Item 4 was checked against agentgateway's source at tag `v1.7.0`. The gateway verifies one token per request, so the scope cannot ride in a second token. It can ride as claims in a run token from a second issuer, which the gateway does support. That makes a token issuer the real cost of item 4. The ADR names a fallback that needs no new component.

## Phase 2: people and transport

| Work | Bead | Note |
|---|---|---|
| Keycloak-verified approvers at the gateway's decision route | `adp-0pt` | ADR 0009 says the approver name is unverified until this lands |
| The executor verifies a signed grant | `adp-aty` | Closes ADR 0006's "the executor trusts the controller's word" |
| Spike: Dapr Sentry JWT as caller identity | `adp-3gc` | Identity only; it does not encrypt the hop (bead notes) |
| Remote JWKS, so a signing-key rotation does not need `up.sh` | `adp-k1y` | Open risk "signing keys are a snapshot" |

## Phase 3: delivery and supply chain

| Work | Bead | Note |
|---|---|---|
| Argo CD or Flux owns `platform/`; `up.sh` bootstraps only the controller | `adp-m3l` | Changes ADR 0022's suspend from a script to a commit plus a break-glass path |
| Sign images, publish SBOMs, verify at admission | `adp-r2g` | Needs a registry |
| `dagger call check` on push to `main` | `adp-lcd` | Small; do it with the first Phase 3 PR |
| Terraform root for the AWS resources | `adp-6j0` | Only useful with a real account; see decisions |

## Phase 4: an agent is one resource

`adp-7w8`: onboarding is hand-edited YAML in two places plus a `boundary_register.yaml` entry. Offer one `Agent` resource that renders the ServiceAccount, the tenant network policy and the entitlements.

- Use a Crossplane composition, not a Kratix Promise. The cell-platform prototype tested both on the same clusters and chose Crossplane for staged rollout by revision channel and immutable revisions per edit.
- Blocker to check first: entitlements live in one file, `platform/gateway/models.yaml`. A composition needs one object per agent. Whether agentgateway's allow-lists can be split that way is not verified.
- Do this after Phase 3. A composition delivered by `up.sh` would be rewritten when GitOps lands.

## Considered and left out

- **A model reviewer for in-scope actions** (the guide's Auto-review). ADR 0011 already states "No model grades another model's output", and the only side-effecting action here, an ERP commit, has a named human. Revisit when an agent gets a second tool with side effects.
- **Production model serving** (ADR 0019). Still document-only. It needs a target environment.
- **Gateway HA and shared rate limiting** (`adp-7jx`). One replica is correct for one laptop.
- **A learned baseline for `GatewayTokenVelocity`.** ADR 0016 explains why there is not enough history.

## Decisions for you

1. **TLS: cert-manager listener or a mesh?** The plan assumes the listener. A mesh (`adp-uae`) would also cover the other hops and would change Phase 2.
2. **Is a real AWS account in scope?** `adp-6j0`, and the "dummy static credentials" and "nothing ran against real AWS" risks, stay open without one.
3. **Should the `agents` namespace become a cell?** The cell-platform prototype's fences (four directions, tenant-proof) are a superset of this repo's tenant policy. Joining them makes Phase 4 a `Cell` plus an `Agent`, at the cost of coupling two repos that are separate today.

## What I did not check

- No cluster was started. Every "today" claim comes from reading the README, `docs/threat-model.md`, ADRs 0006, 0009, 0011, 0016 and 0019, the bead list, and a grep of `platform/`, `scripts/`, `agent/`, `erp/`, `tools/` and `sandbox/` for CronJob, suspend, object lock and retention.
- For ADR 0020, agentgateway's source was read at tag `v1.7.0` (JWT providers, the CEL variable list, the rate-limit key). Nothing was run, and two points are still open in the ADR. Phase 4's blocker was not checked.
- The guide's own links (its recommended cyber configuration, its gateway or proxy guidance) were lost in PDF text extraction and not followed.
