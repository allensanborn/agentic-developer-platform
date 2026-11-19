// CI for the platform. The laptop and GitHub Actions run the same functions:
//
//	dagger call check
//
// Every tool image is pinned by tag and digest.
package main

import (
	"context"
	"fmt"

	"dagger/ci/internal/dagger"

	"golang.org/x/sync/errgroup"
)

const (
	shellcheckImage  = "koalaman/shellcheck-alpine:v0.11.0@sha256:9955be09ea7f0dbf7ae942ac1f2094355bb30d96fffba0ec09f5432207544002"
	hadolintImage    = "hadolint/hadolint:v2.14.0-alpine@sha256:7aba693c1442eb31c0b015c129697cb3b6cb7da589d85c7562f9deb435a6657c"
	kustomizeImage   = "registry.k8s.io/kustomize/kustomize:v5.8.1@sha256:899fcd3bc898160e62bcaf82932b0cb29ba38d16272353db2e7acbba82129429"
	kubeconformImage = "ghcr.io/yannh/kubeconform:v0.7.0-alpine@sha256:8f0eeaaa96ba27ba1500b0e4b1c215acc358d159c62a7ecae58d7a03403287b0"
	trivyImage       = "aquasec/trivy:0.76.2@sha256:8f6bb947dbc528902e11f2f5be52f7b519f6a39d5d148f41166f2040499768fb"
	gitleaksImage    = "zricethezav/gitleaks:v8.30.1@sha256:c00b6bd0aeb3071cbcb79009cb16a60dd9e0a7c60e2be9ab65d25e6bc8abbb7f"
	pythonImage      = "python:3.13-slim-bookworm@sha256:a5a7017efc5969e00ae2b91c8eb0631049a569652aa4ffc4501769049ae45c72"
	prometheusImage  = "prom/prometheus:v3.15.1@sha256:fa3302279710be2f21a8301ec17a8b4f2301fd829bd113839b3b6b02b6f191a2"
	renovateImage    = "renovate/renovate:44.216.2@sha256:435c302302f1db679e9b482f8dfd7e1e0c3b6938df44f9444780064c9a4d2c4f"
)

type Ci struct{}

// Lint shell scripts, the Dockerfile, and the rendered Kubernetes manifests.
func (m *Ci) Lint(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", ".beads", ".scratch", ".devbox", ".kubeconfig"]
	src *dagger.Directory,
) error {
	g, ctx := errgroup.WithContext(ctx)
	g.Go(func() error {
		_, err := dag.Container().From(shellcheckImage).
			WithDirectory("/src", src).WithWorkdir("/src").
			WithExec([]string{"sh", "-c", "shellcheck -x scripts/*.sh"}).Sync(ctx)
		return err
	})
	g.Go(func() error {
		_, err := dag.Container().From(hadolintImage).
			WithDirectory("/src", src).WithWorkdir("/src").
			WithExec([]string{"hadolint", "agent/Dockerfile", "erp/app/Dockerfile", "erp/db/Dockerfile", "tools/orders-mcp/Dockerfile", "sandbox/broker/Dockerfile", "sandbox/runtime/Dockerfile"}).Sync(ctx)
		return err
	})
	g.Go(func() error {
		rendered := dag.Container().From(kustomizeImage).
			WithDirectory("/src", src).WithWorkdir("/src").
			WithDirectory("/rendered", dag.Directory()).
			WithExec([]string{"kustomize", "build", "platform", "-o", "/rendered/platform.yaml"}).
			WithExec([]string{"kustomize", "build", "erp/deploy", "-o", "/rendered/erp.yaml"}).
			WithExec([]string{"kustomize", "build", "tools/deploy", "-o", "/rendered/tools.yaml"}).
			WithExec([]string{"kustomize", "build", "sandbox/deploy", "-o", "/rendered/sandbox.yaml"}).
			Directory("/rendered")
		// Built-in kinds are validated strictly. CRD kinds (agentgateway, Dapr, External
		// Secrets) have no published schemas here and are validated by the API server
		// when scripts/up.sh applies them.
		_, err := dag.Container().From(kubeconformImage).
			WithDirectory("/rendered", rendered).
			WithExec([]string{"/kubeconform", "-strict", "-summary", "-ignore-missing-schemas", "/rendered"}).
			Sync(ctx)
		return err
	})
	return g.Wait()
}

// Test runs one Python directory's unit tests against the hash-pinned dependencies.
func (m *Ci) Test(
	ctx context.Context,
	// +defaultPath="/agent"
	src *dagger.Directory,
) (string, error) {
	return dag.Container().From(pythonImage).
		WithEnvVariable("PYTHONDONTWRITEBYTECODE", "1").
		WithDirectory("/app", src).WithWorkdir("/app").
		WithExec([]string{"pip", "install", "-q", "--no-cache-dir", "--require-hashes", "-r", "requirements.txt"}).
		WithExec([]string{"pip", "install", "-q", "--no-cache-dir", "pytest==9.2.0"}).
		WithExec([]string{"python", "-m", "pytest", "-q", "-p", "no:cacheprovider"}).
		Stdout(ctx)
}

// Build an image from the Dockerfile in a directory.
func (m *Ci) Build(
	// +defaultPath="/agent"
	src *dagger.Directory,
) *dagger.Container {
	return src.DockerBuild()
}

// Scan for committed secrets, misconfigured manifests, and known vulnerabilities in
// dependencies and in the built image. HIGH and CRITICAL findings fail the build.
func (m *Ci) Scan(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".beads", ".scratch", ".devbox", ".kubeconfig", ".dagger/internal", ".dagger/dagger.gen.go"]
	src *dagger.Directory,
) error {
	trivy := dag.Container().From(trivyImage).
		// Locked: one scan at a time holds the DB. Five parallel scans sharing it crashed trivy
		// (SIGSEGV/SIGBUS in bbolt) on Dagger 0.21.11, arm64.
		WithMountedCache("/root/.cache/trivy", dag.CacheVolume("trivy-db"),
			dagger.ContainerWithMountedCacheOpts{Sharing: dagger.CacheSharingModeLocked}).
		WithDirectory("/src", src.WithoutDirectory(".git")).WithWorkdir("/src")
	fail := []string{"--exit-code", "1", "--severity", "HIGH,CRITICAL", "--quiet"}

	g, ctx := errgroup.WithContext(ctx)
	g.Go(func() error { // secrets, across the full git history
		_, err := dag.Container().From(gitleaksImage).
			WithDirectory("/src", src).WithWorkdir("/src").
			WithExec([]string{"gitleaks", "git", "--no-banner", "--redact", "."}).Sync(ctx)
		return err
	})
	g.Go(func() error { // Kubernetes and Dockerfile misconfiguration
		_, err := trivy.WithExec(append([]string{"trivy", "config"}, append(fail, ".")...)).Sync(ctx)
		return err
	})
	g.Go(func() error { // dependency vulnerabilities and secrets in the working tree
		_, err := trivy.WithExec(append([]string{"trivy", "fs", "--scanners", "vuln,secret"}, append(fail, ".")...)).Sync(ctx)
		return err
	})
	for _, dir := range []string{"agent", "erp/app", "erp/db", "tools/orders-mcp", "sandbox/broker", "sandbox/runtime"} { // the images that would ship
		g.Go(func() error {
			image := m.Build(src.Directory(dir)).AsTarball()
			_, err := trivy.WithFile("/image.tar", image).
				WithExec(append([]string{"trivy", "image", "--input", "/image.tar", "--ignore-unfixed"}, fail...)).Sync(ctx)
			return err
		})
	}
	return g.Wait()
}

// Boundaries verifies boundary_register.yaml: every identifier two components must agree on
// (audience, ServiceAccount subjects, model aliases, secret names, labels) is the same literal
// on both sides, at the cited line of a file whose sha256 is unchanged. No model, no cluster.
func (m *Ci) Boundaries(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", ".beads", ".scratch", ".devbox", ".kubeconfig"]
	src *dagger.Directory,
) (string, error) {
	return dag.Container().From(pythonImage).
		WithEnvVariable("PYTHONDONTWRITEBYTECODE", "1").
		WithDirectory("/src", src).WithWorkdir("/src").
		WithExec([]string{"pip", "install", "-q", "--no-cache-dir", "--require-hashes", "-r", "tools/boundary/requirements.txt"}).
		WithExec([]string{"python", "tools/boundary/boundary.py", "verify"}).
		Stdout(ctx)
}

// Harness verifies harness.lock: every file a coding agent executes from this repo (.claude/,
// .mcp.json, AGENTS.md, CLAUDE.md) matches its locked sha256, and devbox.json has no init_hook.
// A harness change has to relock in the same PR (ADR 0013). Standard library only.
func (m *Ci) Harness(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".git", ".beads", ".scratch", ".devbox", ".kubeconfig"]
	src *dagger.Directory,
) (string, error) {
	return dag.Container().From(pythonImage).
		WithEnvVariable("PYTHONDONTWRITEBYTECODE", "1").
		WithDirectory("/src", src).WithWorkdir("/src").
		WithExec([]string{"python", "-I", "tools/harness/harness.py", "verify"}).
		Stdout(ctx)
}

// RenovateConfig validates renovate.json5 strictly. Offline, so it runs in every check.
func (m *Ci) RenovateConfig(
	ctx context.Context,
	// +defaultPath="/renovate.json5"
	config *dagger.File,
) (string, error) {
	return dag.Container().From(renovateImage).
		WithFile("/src/renovate.json5", config).WithWorkdir("/src").
		WithExec([]string{"renovate-config-validator", "--strict"}).
		Stdout(ctx)
}

// Renovate proposes bumps for every pin renovate.json5 covers (ADR 0012). By default it reads
// the source tree on Renovate's local platform and only logs what it would change; the token,
// if given, is used for registry and GitHub lookups. With --pull-requests it runs against
// GitHub instead and opens or updates pull requests, which needs a token that may do that.
func (m *Ci) Renovate(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".beads", ".scratch", ".devbox", ".kubeconfig", ".dagger/internal", ".dagger/dagger.gen.go"]
	src *dagger.Directory,
	// GitHub token. Read-only is enough for a local report; --pull-requests needs contents
	// and pull-requests write on the repository.
	// +optional
	token *dagger.Secret,
	// Open or update pull requests on GitHub instead of reporting locally.
	// +optional
	pullRequests bool,
	// +optional
	// +default="allensanborn/agentic-developer-platform"
	repository string,
) (string, error) {
	renovate := dag.Container().From(renovateImage).
		WithEnvVariable("LOG_LEVEL", "info").
		// The slim image installs uv, go and helm on demand for lockfile updates.
		WithEnvVariable("RENOVATE_BINARY_SOURCE", "install").
		WithMountedCache("/tmp/renovate/cache", dag.CacheVolume("renovate"),
			dagger.ContainerWithMountedCacheOpts{Owner: "12021"})
	if pullRequests {
		if token == nil {
			return "", fmt.Errorf("--pull-requests needs --token")
		}
		return renovate.
			WithSecretVariable("RENOVATE_TOKEN", token).
			WithEnvVariable("RENOVATE_PLATFORM", "github").
			WithEnvVariable("RENOVATE_REPOSITORIES", repository).
			WithEnvVariable("RENOVATE_ONBOARDING", "false").
			WithEnvVariable("RENOVATE_REQUIRE_CONFIG", "required").
			WithExec([]string{"renovate"}).
			Stdout(ctx)
	}
	if token != nil {
		renovate = renovate.WithSecretVariable("RENOVATE_GITHUB_COM_TOKEN", token)
	}
	return renovate.
		WithDirectory("/src", src, dagger.ContainerWithDirectoryOpts{Owner: "12021"}).WithWorkdir("/src").
		WithEnvVariable("RENOVATE_PLATFORM", "local").
		WithEnvVariable("RENOVATE_REPORT_TYPE", "logging").
		WithExec([]string{"renovate"}).
		Stdout(ctx)
}

// Alerts checks and unit-tests the alert rules in platform/telemetry/ (alerts_test.yml): each
// detection fires on its case and stays quiet beside it, with no cluster (adp-0c0).
func (m *Ci) Alerts(
	ctx context.Context,
	// +defaultPath="/platform/telemetry"
	src *dagger.Directory,
) (string, error) {
	return dag.Container().From(prometheusImage).
		WithDirectory("/rules", src).WithWorkdir("/rules").
		WithExec([]string{"promtool", "check", "rules", "alerts.yml"}).
		WithExec([]string{"promtool", "test", "rules", "alerts_test.yml"}).
		Stdout(ctx)
}

// Check is the single CI entrypoint: lint, test, boundaries, harness lock, Renovate config, alert rules, scan.
func (m *Ci) Check(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".beads", ".scratch", ".devbox", ".kubeconfig", ".dagger/internal", ".dagger/dagger.gen.go"]
	src *dagger.Directory,
) error {
	g, ctx := errgroup.WithContext(ctx)
	g.Go(func() error { return m.Lint(ctx, src.WithoutDirectory(".git")) })
	for _, dir := range []string{"agent", "erp/app"} {
		g.Go(func() error { _, err := m.Test(ctx, src.Directory(dir)); return err })
	}
	g.Go(func() error { _, err := m.Boundaries(ctx, src.WithoutDirectory(".git")); return err })
	g.Go(func() error { _, err := m.Harness(ctx, src.WithoutDirectory(".git")); return err })
	g.Go(func() error { _, err := m.RenovateConfig(ctx, src.File("renovate.json5")); return err })
	g.Go(func() error { _, err := m.Alerts(ctx, src.Directory("platform/telemetry")); return err })
	g.Go(func() error { return m.Scan(ctx, src) })
	return g.Wait()
}
