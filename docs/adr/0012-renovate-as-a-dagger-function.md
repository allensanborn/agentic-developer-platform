# 12. Renovate runs as a Dagger function, with a per-run App token

Status: accepted, 2026-11-18. The function, config check and workflow are built. The GitHub App (`RENOVATE_APP_CLIENT_ID`, `RENOVATE_APP_PRIVATE_KEY`) is not created yet, so the scheduled run fails at the token step until it is.

## Context

Every image, chart, action and Python package is pinned by digest, hash or SHA. Pinning stops substitution but holds a version in place until someone moves it. GTIG (Nov 2026) reports automated patch-diff exploitation that took a disclosure to a mass-exploitation campaign in four days, so a pin nobody bumps is a known-vulnerable version held deliberately. Nothing here moved pins on its own.

## Decision

- Renovate runs only as `dagger call renovate`, on a digest-pinned `renovate/renovate` image: the same container on a laptop and in Actions, like every other CI step. No hosted Renovate app is installed.
- By default it runs on Renovate's local platform and only logs what it would change. A token, if given, is used for lookups. `--pull-requests` switches it to GitHub, where it opens pull requests.
- `dagger call check` validates `renovate.json5` strictly, offline, so a broken config fails a PR rather than the weekly run.
- Ordinary updates wait 3 days after release (a hijacked release is usually caught within that) and land on Mondays. Updates that fix a known vulnerability (OSV) skip both.
- The scheduled workflow mints a GitHub App installation token per run, scoped to this repository and expiring in an hour. Pull requests opened with the workflow's own `GITHUB_TOKEN` would not trigger CI, and a stored PAT is the long-lived credential this repo avoids everywhere else.
- Python locks are compiled with `uv pip compile --universal --python-version=3.13 --output-file=…`. Renovate's pip-compile manager rejects `--python-platform` and `-o`; `--universal` is accepted and gives a lock that is valid on Linux and macOS alike. The Python image is held to 3.13 digests, because a new minor changes both the image and the lock's target.

## Consequences

- Dagger engine and `.dagger` Go module bumps arrive as one PR labelled `needs-dagger-develop`. Someone has to run `dagger develop` on it, because Renovate cannot regenerate the SDK.
- `versions.env` bumps (cluster components) are labelled `needs-smoke`. CI cannot prove them; `scripts/smoke.sh` on a fresh `up.sh` can.
- `versions.env` entries are not digest-pinned. `helm --version` and k3d's image flag take a bare version, and `K3S_IMAGE` by digest is untested.
- The App holds `contents`, `pull-requests`, `issues` and `workflows` write on this repository. `workflows` is needed because Renovate updates action SHAs in `.github/workflows/`. Whoever controls the App's private key can push branches here, so it is a secret like a provider key.
