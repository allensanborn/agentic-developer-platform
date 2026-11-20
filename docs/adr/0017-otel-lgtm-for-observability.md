# 17. otel-lgtm for observability, with Prometheus-format rules and Alertmanager

Status: accepted, 2026-11-20. Built. Replaces the Jaeger (adp-bio) and standalone Prometheus (ADR 0016) deployments.

## Context

Traces went to Jaeger and metrics to a separate Prometheus. There was no log store, no UI beyond Jaeger's, and alerts reached nothing. The user asked for the stack that most resembles what production teams run. The common production shape is OpenTelemetry instrumentation into a Collector, with Prometheus or Mimir, Tempo, Loki and Grafana behind it.

## Decision

- **One `grafana/otel-lgtm` pod** (0.40.0, pinned by digest) holds the OTel Collector, Prometheus, Tempo, Loki, Pyroscope and Grafana. The gateway and the agents speak only OTLP to its Collector. The production form is Grafana's Helm charts or Grafana Cloud, the same components behind the same protocol, so moving is a change of endpoint, not of instrumentation. Upstream says this image is for development, demo and testing, and that's how it's used here.
- **The gateway sends all three signals:** spans to Tempo; its access log over OTLP to Loki, with `jwt_sub`, model, tokens, endpoint and `trace_id` as structured metadata; and caller-labelled metrics, which are scraped.
- **Alerting stays Prometheus-format.** `alerts.yml` is mounted into the pod's Prometheus, still tested by `promtool` in `dagger call check`, and Prometheus sends to a separate Alertmanager. Grafana shows those alerts through an Alertmanager data source. Grafana Cloud's Mimir ruler and Alertmanager take the same rule files and the same model, so the rules carry over. Grafana-managed alert rules were not chosen: they would move the rules out of a tested file into Grafana.
- **Grafana:**
  - Anonymous access is **Viewer**; upstream's default is Admin.
  - The login form and basic auth are off, so there is no admin credential to keep or leak.
  - Data sources come from files.
- **Policies:** the pod takes only OTLP in, from the gateway and the agents. A CiliumNetworkPolicy allows out only DNS, the two scrape targets and Alertmanager. The image's start-up download of a Grafana plugin is therefore blocked, and Grafana runs without it.

## Found while building

- Non-root (Pod Security `restricted`) with a read-only root (trivy KSV-0014), the image writes only where something is mounted: `/data`, `/tmp` (the launcher's readiness marker), and, outside `/data`, Tempo's `/var/tempo` and Loki's `/loki`. Upstream runs as root, so its manifest doesn't hit this. Each needs a mounted volume, or Tempo exits and the launcher kills the whole pod. This showed up as a crash loop with every component restarting.
- `scripts/up.sh` deletes the old Jaeger and Prometheus objects, because `kubectl apply` does not remove what the manifests stopped declaring.

## Added 2026-11-20

- **Durable storage.** The pod's state is on a 10 Gi PersistentVolumeClaim (`lgtm-data`), as subdirectories for `/data`, `/var/tempo` and `/loki`. The Deployment rolls with `Recreate`, since the volume is ReadWriteOnce. Prometheus keeps 7 days (or 4 GB). Tested: a run's trace (10 spans), its 3 Loki lines and 30 minutes of metrics were all still there after a pod restart. The volume does not survive `k3d cluster delete`.
- **A webhook receiver.** Alertmanager delivers to `alert-receiver`, a standard-library Python server that logs each alert as a JSON line. Pointing at a real endpoint is a URL change in `alertmanager.yml` plus an egress rule. `smoke.sh` checks delivery end to end, and checks that Alertmanager received a firing alert by its counter, because a one-minute burst alert leaves the active list before a slow check reads it.
- **A provisioned dashboard**, "ADP: AI gateway" (`platform/telemetry/dashboards/`). It shows tokens per minute and refusals per caller, requests by status, model latency p95, tool calls, policy-denied drops, firing alerts, the Loki access log and Tempo traces. `smoke.sh` runs each Prometheus panel query that its own traffic feeds and requires data, so a renamed metric fails the check instead of drawing an empty panel.


- The image bundles component versions. Renovate bumps the image as a whole, not Tempo or Loki separately.
- `smoke.sh` checks:
  - one run is one trace in Tempo;
  - its access log is in Loki by caller and trace id;
  - the scrape targets are up;
  - both alerts fire, and the burst alert reaches Alertmanager;
  - Grafana is read-only and has no login;
  - agents cannot reach any query port.
