// CI for the platform. The laptop and GitHub Actions run the same functions:
//
//	dagger call check
//
// Every tool image is pinned by tag and digest.
package main

import (
	"context"

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
			WithExec([]string{"hadolint", "agent/Dockerfile"}).Sync(ctx)
		return err
	})
	g.Go(func() error {
		rendered := dag.Container().From(kustomizeImage).
			WithDirectory("/src", src).WithWorkdir("/src").
			WithExec([]string{"kustomize", "build", "platform", "-o", "/rendered.yaml"}).
			File("/rendered.yaml")
		// Built-in kinds are validated strictly. CRD kinds (agentgateway, Dapr, External
		// Secrets) have no published schemas here and are validated by the API server
		// when scripts/up.sh applies them.
		_, err := dag.Container().From(kubeconformImage).
			WithFile("/rendered.yaml", rendered).
			WithExec([]string{"/kubeconform", "-strict", "-summary", "-ignore-missing-schemas", "/rendered.yaml"}).
			Sync(ctx)
		return err
	})
	return g.Wait()
}

// Test runs the agent's unit tests against the hash-pinned dependencies.
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

// Build the agent image from its Dockerfile.
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
		WithMountedCache("/root/.cache/trivy", dag.CacheVolume("trivy-db")).
		WithDirectory("/src", src.WithoutDirectory(".git")).WithWorkdir("/src")
	fail := []string{"--exit-code", "1", "--severity", "HIGH,CRITICAL", "--no-progress"}

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
	g.Go(func() error { // the image that would ship
		image := m.Build(src.Directory("agent")).AsTarball()
		_, err := trivy.WithFile("/image.tar", image).
			WithExec(append([]string{"trivy", "image", "--input", "/image.tar", "--ignore-unfixed"}, fail...)).Sync(ctx)
		return err
	})
	return g.Wait()
}

// Check is the single CI entrypoint: lint, test, scan.
func (m *Ci) Check(
	ctx context.Context,
	// +defaultPath="/"
	// +ignore=[".beads", ".scratch", ".devbox", ".kubeconfig", ".dagger/internal", ".dagger/dagger.gen.go"]
	src *dagger.Directory,
) error {
	g, ctx := errgroup.WithContext(ctx)
	g.Go(func() error { return m.Lint(ctx, src.WithoutDirectory(".git")) })
	g.Go(func() error { _, err := m.Test(ctx, src.Directory("agent")); return err })
	g.Go(func() error { return m.Scan(ctx, src) })
	return g.Wait()
}
