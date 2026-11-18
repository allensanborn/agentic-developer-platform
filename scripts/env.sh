# shellcheck shell=bash
# Sourced by every script: pinned versions and a repo-local kubeconfig.
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A caller's CLUSTER wins over versions.env's default, so a second cluster can run beside
# the first: CLUSTER=adp-sb scripts/up.sh.
_cluster=${CLUSTER:-}
# shellcheck source=versions.env
set -a; . "$ROOT/versions.env"; set +a
CLUSTER=${_cluster:-$CLUSTER}
export KUBECONFIG="$ROOT/.kubeconfig"
