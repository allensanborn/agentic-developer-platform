# shellcheck shell=bash
# Sourced by every script: pinned versions and a repo-local kubeconfig.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=versions.env
set -a; . "$ROOT/versions.env"; set +a
export KUBECONFIG="$ROOT/.kubeconfig"
