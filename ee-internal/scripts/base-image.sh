#!/usr/bin/env bash
# Print images.base_image.name from an ansible-builder v3 definition and fail
# unless it is pinned by a real digest.
#
# Usage: base-image.sh [execution-environment.yml]
set -euo pipefail

file=${1:-execution-environment.yml}

base=$(python3 - "$file" <<'EOF'
import sys
import yaml

with open(sys.argv[1]) as fh:
    print(yaml.safe_load(fh)["images"]["base_image"]["name"])
EOF
)

if [[ ! $base =~ @sha256:[0-9a-f]{64}$ ]]; then
  echo "ERROR: base_image must be pinned by digest (…@sha256:<64 hex>): $base" >&2
  exit 1
fi
if [[ $base =~ @sha256:0{64}$ ]]; then
  echo "ERROR: base_image still has the placeholder digest: $base" >&2
  exit 1
fi

echo "$base"
