# 18. The host's GPU model is a first-class development backend, with bounds

Status: accepted, 2026-11-20. Built. Amended by ADR 0024: the host also serves `llama3.1:8b`, for ERP diagnosis only. Decided with a turtleneck review (full level); the record's flip conditions are below.

## Context

`smart` failed over from OpenRouter (placeholder key) to the host's Ollama, then to an in-cluster Llama 3.2 3B. Docker on macOS has no GPU, so the in-cluster model runs on CPU and takes 10–20 s per short reply. The host's Ollama has the Metal GPU, but nothing managed it: it was usually not running, `smart` fell over to the slow model, and smoke skipped a check. The machine is an M5 Pro with 24 GB, 16 GB of it given to the OrbStack VM.

The options weighed:
- **A. Host GPU, first-class** (this decision).
- **B. Cluster CPU only:** contained but slow. An 8B model on CPU doesn't fit beside the observability stack in the VM.
- **C. Hosted for quality:** breaks offline, and on provider rate limits.
- **D. Defer.**

Each ties `smart`'s quality to exactly one resource. The `smart` alias's failover order is the real boundary, so this choice stays cheap to change.

## Decision

`smart` = OpenRouter, then the host GPU model, then the in-cluster 3B. The host backend is bounded:
- **Loopback only.** Homebrew's launchd service (`brew services`) binds `127.0.0.1:11434`. Verified 2026-11-20: the cluster reaches it through OrbStack's `host.docker.internal` forwarding, and the Mac's LAN address does not. The Ollama API has no authentication, so loopback is its only fence. `scripts/host-model.sh status` fails if anything listens beyond loopback.
- **One pinned model:** `llama3.2:3b`, about 2.0 GB, the same model as the in-cluster fallback, so `smart` answers alike on either path, just faster on the GPU. It's pinned by the sha256 of its Ollama manifest in `versions.env`, and `status` fails on any other digest. The boundary register ties the name in `versions.env` to the one in `models.yaml`.
- **Why not the 8B first chosen.** `llama3.1:8b` (4.9 GB) was built and measured, and it tripped this ADR's second flip condition. Over one full-stack smoke run, swap grew 7.7 GB with it and 0.7 GB without, and free memory bottomed at 24% against 33%, on the 24 GB machine with 16 GB given to the VM. With the 3B, the same run grew swap by 2.4 GB, with free memory at 28% at its lowest: a cost, well short of the 8B's. Qwen3 4B was set aside: by default it reasons in a "thinking" mode that can reach the reply text through the OpenAI-compatible API (unverified here). The research agent would show that.
- **Reported, not required.** `up.sh` prints the host model's status. Without it, `smart` falls through to the cluster.

## Consequences

- **We give up** the claim that every model backend sits inside the cluster's network policy, **to get** fast, offline-capable GPU inference for development and live demos. Threat-model row 22 states the exception.
- The model takes about 2 GB of the host's memory beside the VM.
- The host model isn't in CI, which never runs it. The pin and loopback check run on developer machines only.

## Flips if

- OrbStack stops reaching a loopback-bound service, so Ollama would have to listen on the LAN. Then drop the host backend: hosted, then cluster.
- The full stack plus the 8B model swaps under a smoke run. Then use a smaller host model, or hosted-only.
- The development or demo machine becomes Linux with an NVIDIA GPU. Then the GPU goes into the cluster (device plugin) and this host process retires.
- A demo must show that data never leaves the machine. Then put the host model first in `smart`'s order.
