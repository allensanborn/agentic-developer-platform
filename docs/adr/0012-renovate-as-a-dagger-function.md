# 12. Renovate runs as a Dagger function, locally

Status: accepted, 2026-11-18. Amended 2026-11-25: Renovate runs only when a person runs it, locally. It is for local upgrades, so the scheduled workflow is removed and its GitHub App is not created.

## Context

Every image, chart, action and Python package is pinned by digest, hash or SHA. Pinning stops substitution but holds a version in place until someone moves it. GTIG (Nov 2026) reports automated patch-diff exploitation that took a disclosure to a mass-exploitation campaign in four days, so a pin nobody bumps is a known-vulnerable version held deliberately. Nothing here moved pins on its own.

## Decision

- Renovate runs only as `dagger call renovate`, on a digest-pinned `renovate/renovate` image: the same container on a laptop and in Actions, like every other CI step. No hosted Renovate app is installed.
- By default it runs on Renovate's local platform and only logs what it would change. A token, if given, is used for lookups. `--pull-requests` switches it to GitHub, where it opens pull requests.
- `dagger call check` validates `renovate.json5` strictly, offline, so a broken config fails a PR rather than the weekly run.
- Ordinary updates wait 3 days after release (a hijacked release is usually caught within that) and land on Mondays. Updates that fix a known vulnerability (OSV) skip both.
- No scheduled run and no GitHub App (amended 2026-11-25). A person runs it locally and lands the bumps. `--pull-requests` with the person's own `gh auth token` opens them as PRs.
- Python locks are compiled with `uv pip compile --universal --python-version=3.13 --output-file=…`. Renovate's pip-compile manager rejects `--python-platform` and `-o`; `--universal` is accepted and gives a lock that is valid on Linux and macOS alike. The Python image is held to 3.13 digests, because a new minor changes both the image and the lock's target.

## Consequences

- Dagger engine and `.dagger` Go module bumps arrive as one PR labelled `needs-dagger-develop`. Someone has to run `dagger develop` on it, because Renovate cannot regenerate the SDK.
- `versions.env` bumps (cluster components) are labelled `needs-smoke`. CI cannot prove them; `scripts/smoke.sh` on a fresh `up.sh` can.
- `versions.env` entries are not digest-pinned. `helm --version` and k3d's image flag take a bare version, and `K3S_IMAGE` by digest is untested.
- Nothing bumps a pin between local runs. GitHub's Dependabot alerts still flag a known-vulnerable dependency in the meantime; acting on one is a local Renovate run.
- No write credential for the repository exists outside the maintainer's own.
