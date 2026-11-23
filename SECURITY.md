# Security policy

## Report a vulnerability

Report a suspected vulnerability privately through GitHub: open the repository's **Security** tab and choose **Report a vulnerability**, or go straight to <https://github.com/allensanborn/agentic-developer-platform/security/advisories/new>. Do not open a public issue for it.

The security contact is the maintainer, Allen Sanborn ([@allensanborn](https://github.com/allensanborn)). The private report form reaches the maintainer directly.

## What happens next

| Step | Time from your report |
|---|---|
| Acknowledgement | within 7 days |
| Assessment and a planned fix date | within 14 days |
| Fix or documented mitigation | within 90 days |

The maintainer agrees a disclosure date with you and discloses earlier when a fix is ready. Confirmed vulnerabilities are published as [GitHub Security Advisories](https://github.com/allensanborn/agentic-developer-platform/security/advisories) on this repository, with credit to the reporter unless you decline it.

## Supported versions

The project has made no release. Only the head of `main` is supported, and fixes land there. If the project starts making releases, this section will state how long each release is supported and when it stops receiving security updates.

## Scope

The platform runs on a local k3d cluster. [docs/threat-model.md](docs/threat-model.md) lists the assets, trust boundaries, threats and controls, and the open risks that are already known. A report that matches an open risk there is still welcome, but it is not new.

## Secrets and credentials

- **Storage.** No secret or credential is committed. Model-provider API keys live in AWS Secrets Manager (emulated locally by floci), and External Secrets delivers them to the gateway ([ADR 0003](docs/adr/0003-provider-keys-in-secrets-manager.md)). The only write path is `scripts/provider-key.sh`, which reads the key from stdin. CI credentials are GitHub Actions secrets. The Renovate workflow reads a GitHub App private key from `RENOVATE_APP_PRIVATE_KEY` and mints a one-hour token scoped to this repository on each run.
- **Detection.** GitHub secret scanning and push protection are on. `dagger call check` runs gitleaks over the full history and Trivy's secret scanner on every pull request.
- **Access.** Only the maintainer can read or change repository settings and Actions secrets. Callers of the gateway never hold a provider key. They authenticate with projected ServiceAccount tokens ([ADR 0002](docs/adr/0002-workload-identity-for-callers.md)).
- **Rotation.** A credential that reaches a commit, a log or an issue is revoked at its issuer the same day. Removing it from history is not enough. Provider keys rotate with `scripts/provider-key.sh` and need no redeploy. Long-lived credentials, the GitHub App key included, are rotated at least once a year.

## Dependency and static-analysis findings

`dagger call check` evaluates every pull request, and the merge is blocked on a violation.

- **Dependencies (SCA).** Trivy scans the hash-locked Python requirements, the Go module and each built image for known vulnerabilities. A HIGH or CRITICAL finding that has a fix blocks the merge. One found on `main` after the fact is fixed within 14 days, and before any release. Renovate opens the update for a known-vulnerable version with no waiting period ([renovate.json5](renovate.json5)). A dependency must carry a license compatible with Apache-2.0.
- **Static analysis (SAST).** shellcheck, hadolint, kubeconform and Trivy's misconfiguration scanner run on every pull request, and GitHub CodeQL scans the Python, the Go and the workflows. Any shellcheck, hadolint or kubeconform finding, a HIGH or CRITICAL misconfiguration, or a CodeQL alert of high severity or above blocks the merge. One found on `main` is fixed within 14 days.

## Findings that do not affect the project

A finding that is not exploitable here is suppressed in the repository, scoped to the file or package it applies to, with a written reason beside it. A CodeQL alert that is a false positive is dismissed in GitHub code scanning with the reason recorded on the alert. A suppression without a reason is not accepted in review. If the project makes a release, those statements ship with it as an OpenVEX document.
