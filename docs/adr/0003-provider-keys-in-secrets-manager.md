# 3. Provider keys live in AWS Secrets Manager, delivered by External Secrets

Status: accepted, 2026-11-10

## Context

Provider keys must not be in git, in an agent's environment, or typed into `kubectl`. They need rotation that does not involve redeploying anything.

## Decision

Keys are stored in AWS Secrets Manager. External Secrets Operator copies each into the gateway's namespace, refreshing every minute. Locally, floci emulates AWS inside the cluster with persistent storage. `scripts/provider-key.sh` is the only write path and reads the key from stdin.

## Consequences

- The same manifests work against real AWS by removing the endpoint override and replacing dummy static credentials with an IAM role scoped to `adp/providers/*`.
- A key still exists as a Kubernetes Secret in one namespace. Encryption at rest for etcd and RBAC on that namespace are the remaining controls.
- AWS resources are created by `up.sh` with the AWS CLI. That is a shortcut; a Terraform root applied unchanged to floci and AWS is the production form.
