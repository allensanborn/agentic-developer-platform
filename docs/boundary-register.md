# Boundary register

`boundary_register.yaml` lists every identifier two components must spell the same way for a call between them to work, and pins each side to the file line that carries it. `dagger call check` verifies it with no model and no cluster (the `Boundaries` step). Format: `boundary-register/1` from [wandercom/pact](https://github.com/wandercom/pact) v1.3.0; the verifier is vendored in `tools/boundary/boundary_register.py` because 1.3.0 is not on PyPI and `pip --require-hashes` cannot install from git.

## What it guards

| Entry | Authority side | Other side(s) | Runtime symptom if they drift |
|---|---|---|---|
| `gateway-audience` | `caller-identity.yaml` `audiences` | each agent's projected token `audience` | 401 on every call |
| `principal-*` (3 names, 2 namespaces) | ServiceAccount `name` / `namespace` | the `<ns>` and `<name>` in each `jwt.sub` allow-list in `models.yaml` | silent 403 |
| `alias-fast`, `alias-smart`, `alias-scripted` | `AgentgatewayModel` name | the alias in `agent/app.py`, `erp/app/graph.py`, `scripts/erp-smoke.sh` | 404 |
| `provider-key-secret` | ExternalSecret target | gateway `auth.secretRef` | hosted model fails, failover hides it |
| `provider-key-remote-ref` | `up.sh` create-secret | ExternalSecret `remoteRef.key` | key never syncs |
| `gateway-client-label` | gateway NetworkPolicy | namespace labels | connection timeout |
| `gateway-mcp-listener` | Gateway listener name | the tools `HTTPRoute` `sectionName` | route unattached, 404 |
| `gateway-mcp-port` | Gateway listener port | the tools NetworkPolicies, `scripts/tools-smoke.sh` | connection timeout |
| `orders-table` | `scripts/tools-up.sh` create-table | the server's `ORDERS_TABLE`, the seed | every lookup "not found" |
| `sandbox-warmpool`, `sandbox-template` | the WarmPool and SandboxTemplate names | the broker's `SANDBOX_WARMPOOL`, the pool's template ref | run_python fails at claim time |
| `runtime-class-gvisor`, `gvisor-node-label` | RuntimeClass name; the node label `sandbox-up.sh` sets | the template's `runtimeClassName`; the RuntimeClass `nodeSelector` | pods never schedule |
| `sandbox-airgap-label` | the template's pod label | the air-gap policy's selector | **air gap fails open** |
| `code-mcp-path` | the broker's HTTPRoute path | `scripts/sandbox-smoke.sh` | 404 |
| `provider-key-not-in-agents` (`absent`) | — | agent manifests must not mention `openrouter-apikey` at all | threat 1 |

Not registered, and why:

- **Issuer** `https://kubernetes.default.svc.cluster.local`: only the gateway writes it. The other side is the API server's runtime config, so it needs an observation record (`kubectl get --raw /.well-known/openid-configuration`), not a file record.
- **Token path**: the manifests write `mountPath: /var/run/secrets/ai-gateway` and `path: token` separately; the apps read the joined `/var/run/secrets/ai-gateway/token`. No single literal appears on both sides, so a file record cannot compare them.
- **`system:serviceaccount:` prefix** of `jwt.sub`: Kubernetes' convention, written on one side only.
- **`scripts/provider-key.sh`** builds `adp/providers/$provider`, which is not a literal.

## Changing a cited file

Every record carries the sha256 of the whole file, so **any** edit to a cited file turns the check red (STALE) until the register is refreshed. That is the operating cost. After editing:

```sh
python3 -m venv .scratch/venv && .scratch/venv/bin/pip install -q --require-hashes -r tools/boundary/requirements.txt  # once
.scratch/venv/bin/python tools/boundary/boundary.py refresh
```

`refresh` re-cites each record from its own path, line and value, then runs `verify`. It refuses, writing nothing, if a value is no longer on its cited line: either the identifier really changed (fix the other side) or lines moved (fix `line:` in the register by hand, then refresh). Never hand-edit a `sha256`. To add a record, add `path`, `line` and `sha256: ''` and refresh. `verify` alone is `boundary.py verify`; the real pact CLI (`pact boundary verify .`) gives the same result.

## Line pinning

pact's `cite` without `--line` pins the first line where the value appears as a token, which is often the wrong one: in `research-agent.yaml`, `ai-gateway` first matches `mountPath: /var/run/secrets/ai-gateway` (line 47), not `audience: ai-gateway` (line 56). Every record here names its line explicitly; when adding one, check by eye that the line is the semantically right one. A record only proves the literal is on that line, not that the line means what the entry says.

## Ceiling

The check compares literals in files. It does not prove the rendered manifests are what the cluster runs, and a value that is computed (an env var override, a shell variable) is invisible to it. `scripts/smoke.sh` remains the runtime proof.
