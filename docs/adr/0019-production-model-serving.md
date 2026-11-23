# 19. Production model serving: KServe-managed vLLM behind the gateway's inference routing

Status: proposed (document only), 2026-11-20. Nothing here runs on the development machine.

## Context

Development serves models from Ollama, on the host's GPU (ADR 0018) or in-cluster on CPU, behind agentgateway aliases. That shape doesn't carry to production. A Service load balancer can't see what decides where an inference request should go: GPU utilisation, KV-cache state, LoRA adapters, queue depth. And Ollama is a single-node convenience, not a serving tier.

## Decision (target)

- **Serving:** KServe on GPU nodes, running vLLM. KServe orchestrates vLLM, SGLang or Triton, and its `LLMInferenceService` adds multi-node serving, prefill/decode split and KV-cache-aware routing.
- **Routing:** the Gateway API Inference Extension (`InferencePool`), which agentgateway implements: it picks a replica by GPU utilisation, KV cache, LoRA adapter and queue depth.
- **Unchanged from development:**
  - Callers still use aliases (`fast`, `smart`).
  - Identity is still the workload token (ADR 0002), and keys stay at the gateway (ADR 0003).
  - Telemetry is still OTLP to a Collector (ADR 0017).
  - A hosted provider stays in each alias's failover list for capacity and outages.

## Consequences

- The aliases and the gateway's policies carry over. Only the backends behind each `AgentgatewayModel` change, from an Ollama URL to an `InferencePool`.
- GPU nodes, model artifact storage and capacity planning become platform concerns. None of that exists today.
- Before this moves from proposed: a target environment, which models per alias, and an eval gate (ADR 0011) that checks a swap of backend behind an alias.
