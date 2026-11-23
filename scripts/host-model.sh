#!/usr/bin/env bash
# The host's GPU model behind `smart` (ADR 0018): Ollama under launchd (Homebrew's service),
# bound to loopback, serving one pinned model. Development only: it is outside the cluster's
# network policy, and the Ollama API has no authentication, so loopback is its only fence.
#
#   scripts/host-model.sh up      start the service, pull the model, verify it
#   scripts/host-model.sh status  exit 0 only when serving the pinned model on loopback alone
#   scripts/host-model.sh down    stop the service
#
# The pin is the sha256 of the model's manifest (versions.env HOST_MODEL_DIGEST). A tag that
# moved upstream fails `status` until the pin is changed on purpose.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"

manifest="$HOME/.ollama/models/manifests/registry.ollama.ai/library/${HOST_MODEL%%:*}/${HOST_MODEL#*:}"

check() {
  curl -sf -m 2 localhost:11434/api/version >/dev/null || { echo "host model: Ollama is not running (scripts/host-model.sh up)"; return 1; }
  for addr in $(lsof -nP -iTCP:11434 -sTCP:LISTEN | awk 'NR > 1 {print $9}' | sort -u); do
    case "$addr" in
      127.0.0.1:* | "[::1]":*) ;;
      *) echo "host model: Ollama listens on $addr, beyond loopback; anything on the network could use it"; return 1 ;;
    esac
  done
  [ -f "$manifest" ] || { echo "host model: $HOST_MODEL is not pulled (scripts/host-model.sh up)"; return 1; }
  have=$(shasum -a 256 "$manifest" | cut -d' ' -f1)
  [ "$have" = "$HOST_MODEL_DIGEST" ] || { echo "host model: $HOST_MODEL is $have, pinned $HOST_MODEL_DIGEST"; return 1; }
  echo "host model: $HOST_MODEL, pinned, loopback only"
}

case "${1:-status}" in
  up)
    command -v ollama >/dev/null || { echo "install Ollama first: brew install ollama" >&2; exit 1; }
    brew services start ollama >/dev/null
    until curl -sf -m 1 localhost:11434/api/version >/dev/null; do sleep 1; done
    ollama pull "$HOST_MODEL" >/dev/null
    check
    ;;
  status) check ;;
  down) brew services stop ollama >/dev/null && echo "host model: stopped" ;;
  *) echo "usage: $0 up|status|down" >&2; exit 2 ;;
esac
