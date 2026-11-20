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
# Cilium (ADR 0014) needs bpffs and a shared cgroup2 mount in each k3d node container. They do
# not survive a node restart, so up.sh applies them every run and sandbox-up.sh after it
# restarts the agent node.
cilium_node_mounts() { # node container name
  docker exec "$1" sh -c '
    grep -qs " /sys/fs/bpf " /proc/mounts || mount bpffs /sys/fs/bpf -t bpf
    mount --make-shared /sys/fs/bpf
    mkdir -p /run/cilium/cgroupv2
    grep -qs " /run/cilium/cgroupv2 " /proc/mounts || mount -t cgroup2 none /run/cilium/cgroupv2
    mount --make-shared /run/cilium/cgroupv2'
}
