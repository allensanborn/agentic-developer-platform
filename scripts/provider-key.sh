#!/usr/bin/env bash
# Set or rotate a model provider's API key. The key goes to AWS Secrets Manager; External
# Secrets delivers it to the gateway within a minute. It is read from stdin (or a hidden
# prompt), so it never lands in shell history, argv or a file.
#   scripts/provider-key.sh openrouter            # prompts
#   op read op://vault/openrouter/key | scripts/provider-key.sh openrouter
set -euo pipefail
provider=${1:?usage: provider-key.sh <provider>}
if [ -t 0 ]; then
  read -rsp "API key for $provider: " key; echo >&2
else
  key=$(cat)
fi
[ -n "$key" ] || { echo "empty key" >&2; exit 1; }
printf '%s' "$key" | "$(dirname "$0")/aws.sh" secretsmanager put-secret-value \
  --secret-id "adp/providers/$provider" --secret-string file:///dev/stdin --query VersionId --output text
