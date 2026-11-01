#!/usr/bin/env bash
# Verify the cosign signature of the ee-deps base image referenced by an
# ansible-builder definition, offline (key pair, no transparency log).
#
# Usage: verify-base.sh [execution-environment.yml]
# Environment: COSIGN_PUBLIC_KEY (path to cosign.pub, or the PEM itself),
#              registry auth via REGISTRY_AUTH_FILE / DOCKER_CONFIG.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
base=$("$here/base-image.sh" "${1:-execution-environment.yml}")

key=${COSIGN_PUBLIC_KEY:?COSIGN_PUBLIC_KEY is required}
if [[ $key == -----BEGIN* ]]; then
  printf '%s\n' "$key" >/tmp/cosign.pub
  key=/tmp/cosign.pub
fi

echo "Verifying $base"
cosign verify --key "$key" --insecure-ignore-tlog=true "$base" | jq .
echo "OK: base image signature verified"
