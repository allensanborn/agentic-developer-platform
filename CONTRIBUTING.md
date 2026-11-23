# Contributing

Contributions are welcome.

## Ask a question or report a defect

Open a [GitHub issue](https://github.com/allensanborn/agentic-developer-platform/issues). Issues are the public place to discuss a proposed change or a problem using the platform. For a defect, say what you ran, what you expected, what happened, and the output of `scripts/smoke.sh` if the cluster is up. Report a security problem privately instead; see [SECURITY.md](SECURITY.md).

## Propose a change

1. Fork the repository and create a branch.
2. Make the change. Keep one topic per pull request.
3. Sign off every commit (see below) and open a pull request against `main`.
4. CI must pass. The maintainer reviews and merges.

Direct pushes to `main` are blocked for everyone, the maintainer included.

## What an acceptable contribution looks like

- Every commit has a `Signed-off-by` line.
- `dagger call check` passes.
- A major change adds or updates automated tests for the behaviour it changes: unit tests beside the code (`test_*.py`), a check in `scripts/smoke.sh` for cluster behaviour, or a rule test in `platform/telemetry/alerts_test.yml`.
- A design decision comes with an ADR in `docs/adr/`. A change to a trust boundary updates [docs/threat-model.md](docs/threat-model.md).
- External versions are pinned: images by digest, Python by hash-locked `requirements.txt`, actions by commit SHA.
- No secrets, and no binaries or generated artifacts.
- A scanner finding is fixed, or suppressed with a written reason as [SECURITY.md](SECURITY.md) describes.

The README's "Common changes" section lists the edits that need a follow-up command, such as refreshing the boundary register.

## Sign your work

This project uses the [Developer Certificate of Origin](https://developercertificate.org/). By signing off you certify that you wrote the change or have the right to submit it under the project's license. Add the line with `git commit -s`:

```
Signed-off-by: Your Name <you@example.com>
```

CI rejects a pull request that contains a commit without it.

## Build and test

The README's "Run it" section lists the required tools and the commands to build the cluster and the images. `devbox shell` provides the pinned tools.

| What | When it runs | How to run it |
|---|---|---|
| Lint, unit tests, boundary register, harness lock, Renovate config, alert rules, secret, misconfiguration and vulnerability scans | CI, on every pull request ([.github/workflows/ci.yml](.github/workflows/ci.yml)) | `dagger call check` |
| End-to-end security checks against a running cluster | By hand, before merging a change to cluster behaviour | `scripts/up.sh`, then `scripts/smoke.sh` |

`dagger call check` runs the same pipeline on a laptop as in CI.

## Dependencies

- **Selection.** A dependency is added when a component needs it, and a new cluster component gets an ADR in `docs/adr/`.
- **Obtaining.** Python packages install from hash-locked `requirements.txt` files compiled from `requirements.in`. Container images are pinned by digest. GitHub Actions are pinned by commit SHA. Cluster component versions are in `versions.env`. The Dagger module's Go dependencies are in `.dagger/go.mod`.
- **Tracking.** Renovate runs daily as a Dagger function ([ADR 0012](docs/adr/0012-renovate-as-a-dagger-function.md), [renovate.json5](renovate.json5)). Ordinary updates wait three days after release. Updates for known-vulnerable versions do not wait. Trivy scans every pull request.
