#!/usr/bin/env bash
# Export a signed ee-deps release as a transfer bundle for the air gap.
#
# Usage: export-bundle.sh IMAGE_REF TAG SBOM OUT_DIR
#   IMAGE_REF  registry/ee/ee-deps@sha256:...  (pushed and cosign-signed)
#   TAG        release tag, e.g. v1.4.0
#   SBOM       CycloneDX SBOM produced by the build job
#   OUT_DIR    directory to write the bundle into
#
# Environment: COSIGN_PRIVATE_KEY (path), COSIGN_PASSWORD, COSIGN_PUBLIC_KEY
# (path or PEM), registry auth via REGISTRY_AUTH_FILE / DOCKER_CONFIG.
#
# Bundle contents (NAME = ee-deps-TAG):
#   NAME.oci.tar          image, oci-archive, digest preserved
#   NAME.sig.oci.tar      cosign signature artifact (sha256-<hex>.sig)
#   NAME.digest           manifest digest (sha256:...)
#   NAME.sbom.cdx.json    CycloneDX SBOM
#   NAME.source           source image reference
#   SHA256SUMS            checksums of all of the above
#   SHA256SUMS.sig        cosign blob signature over SHA256SUMS
set -euo pipefail

ref=${1:?usage: export-bundle.sh IMAGE_REF TAG SBOM OUT_DIR}
tag=${2:?}
sbom=${3:?}
out=${4:?}

[[ $ref =~ ^(.+)@(sha256:[0-9a-f]{64})$ ]] || { echo "IMAGE_REF must be repo@sha256:<digest>: $ref" >&2; exit 1; }
repo=${BASH_REMATCH[1]}
digest=${BASH_REMATCH[2]}
name="ee-deps-${tag}"

pubkey=${COSIGN_PUBLIC_KEY:?COSIGN_PUBLIC_KEY is required}
if [[ $pubkey == -----BEGIN* ]]; then
  printf '%s\n' "$pubkey" >/tmp/cosign.pub
  pubkey=/tmp/cosign.pub
fi

mkdir -p "$out"

echo "--- verify signature before exporting"
cosign verify --key "$pubkey" --insecure-ignore-tlog=true "$ref" >/dev/null

echo "--- image -> $name.oci.tar"
skopeo copy --preserve-digests "docker://$ref" "oci-archive:$out/$name.oci.tar:ee/ee-deps:$tag"
archived=$(skopeo inspect --format '{{.Digest}}' "oci-archive:$out/$name.oci.tar")
[[ $archived == "$digest" ]] || { echo "digest changed during export: $archived != $digest" >&2; exit 1; }

echo "--- signature -> $name.sig.oci.tar"
sig_ref=$(cosign triangulate --type signature "$ref")
skopeo copy --preserve-digests "docker://$sig_ref" "oci-archive:$out/$name.sig.oci.tar"

echo "--- metadata"
printf '%s\n' "$digest" >"$out/$name.digest"
printf '%s\n' "$repo:$tag" "$ref" >"$out/$name.source"
cp "$sbom" "$out/$name.sbom.cdx.json"

echo "--- checksums"
(
  cd "$out"
  rm -f SHA256SUMS SHA256SUMS.sig
  sha256sum -- "$name".* >SHA256SUMS
  cosign sign-blob --yes --tlog-upload=false --key "$COSIGN_PRIVATE_KEY" \
    --output-signature SHA256SUMS.sig SHA256SUMS
  cosign verify-blob --key "$pubkey" --insecure-ignore-tlog=true \
    --signature SHA256SUMS.sig SHA256SUMS
  ls -l
)
