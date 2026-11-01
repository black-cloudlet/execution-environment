#!/usr/bin/env bash
# Import a transfer bundle (ee-deps or ee-ci-tools, made by export-bundle.sh)
# into the internal Quay and verify it.
#
# Usage: import-bundle.sh BUNDLE_DIR TARGET_REPO [EE_FILE]
#   BUNDLE_DIR   unpacked export-bundle artifact (contains SHA256SUMS)
#   TARGET_REPO  internal repository, e.g. quay.example.internal/ee/ee-deps
#   EE_FILE      optional: execution-environment.yml whose base_image digest
#                is rewritten in place (commit that change in an MR)
#
# Environment: COSIGN_PUBLIC_KEY (path or PEM). The key must come from your
# own trusted copy, NEVER from the bundle. Push credentials for TARGET_REPO via
# `skopeo login` / REGISTRY_AUTH_FILE.
#
# Steps: checksums -> blob signature over checksums -> copy image + signature
# with digests preserved -> confirm digest -> cosign verify in Quay.
set -euo pipefail

bundle=${1:?usage: import-bundle.sh BUNDLE_DIR TARGET_REPO [EE_FILE]}
target=${2:?usage: import-bundle.sh BUNDLE_DIR TARGET_REPO [EE_FILE]}
ee_file=${3:-}

key=${COSIGN_PUBLIC_KEY:?COSIGN_PUBLIC_KEY is required}
if [[ $key == -----BEGIN* ]]; then
  printf '%s\n' "$key" >/tmp/cosign.pub
  key=/tmp/cosign.pub
fi
key=$(realpath "$key")
[[ -z $ee_file ]] || ee_file=$(realpath "$ee_file")

cd "$bundle"

echo "--- checksums"
sha256sum --check --strict SHA256SUMS
cosign verify-blob --key "$key" --insecure-ignore-tlog=true --signature SHA256SUMS.sig SHA256SUMS

shopt -s nullglob
digests=(*.digest)
((${#digests[@]} == 1)) || { echo "expected exactly one *.digest file in $bundle" >&2; exit 1; }
name=${digests[0]%.digest}
digest=$(<"${digests[0]}")
# first line of NAME.source is "<source repo>:<tag>"
source_ref=$(head -n1 "$name.source")
tag=${source_ref##*:}
[[ $tag =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]{0,127}$ ]] || { echo "bad tag in $name.source: $tag" >&2; exit 1; }
[[ $digest =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "bad digest file: $digest" >&2; exit 1; }

echo "--- image $name -> $target:$tag"
if existing=$(skopeo inspect --format '{{.Digest}}' "docker://$target:$tag" 2>/dev/null); then
  [[ $existing == "$digest" ]] || { echo "ERROR: $target:$tag already exists with digest $existing - tags are immutable" >&2; exit 1; }
  echo "NOTE: $target:$tag already present with the same digest - re-verifying"
fi
skopeo copy --preserve-digests "oci-archive:$name.oci.tar" "docker://$target:$tag"

echo "--- signature -> $target:${digest/:/-}.sig"
skopeo copy --preserve-digests "oci-archive:$name.sig.oci.tar" "docker://$target:${digest/:/-}.sig"

echo "--- digest check"
actual=$(skopeo inspect --format '{{.Digest}}' "docker://$target:$tag")
[[ $actual == "$digest" ]] || { echo "digest mismatch: $target:$tag is $actual, bundle says $digest" >&2; exit 1; }

echo "--- cosign verify"
cosign verify --key "$key" --insecure-ignore-tlog=true "$target@$digest" | jq .

new_ref="$target@$digest"
echo
echo "Imported and verified: $new_ref  (tag $tag)"

if [[ -n $ee_file ]]; then
  sed -E -i "s#^([[:space:]]*name:[[:space:]]*)[^[:space:]]+@sha256:[0-9a-f]{64}#\1${new_ref}#" "$ee_file"
  grep -n "$new_ref" "$ee_file" >/dev/null || { echo "failed to update base_image in $ee_file" >&2; exit 1; }
  echo "Updated base_image in $ee_file - open an MR with this change."
else
  echo "Set images.base_image.name in ee-internal/execution-environment.yml to the reference above."
fi
