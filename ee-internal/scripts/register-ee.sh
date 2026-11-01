#!/usr/bin/env bash
# Create or update (in place) an execution environment in AAP.
#
# Usage: register-ee.sh IMAGE
#   IMAGE  e.g. quay.example.internal/ee/ee-internal:v1.4.0
#
# Environment:
#   AAP_URL          e.g. https://aap.example.internal (platform gateway)
#   AAP_TOKEN        OAuth token, controller admin/EE admin       (masked)
#   AAP_REG_CRED_ID  ID of the "Container Registry" credential for Quay
#   AAP_ORG_ID       organization ID; empty = global (org-less) EE
#   AAP_EE_NAME      EE name in AAP (default: global)
#   CURL_CA_BUNDLE   optional CA bundle for AAP's TLS certificate
#
# pull=missing is safe because release tags are immutable. A new release is a
# new tag, so nodes pull it on first use.
set -euo pipefail

image=${1:?usage: register-ee.sh IMAGE}
: "${AAP_URL:?}" "${AAP_TOKEN:?}" "${AAP_REG_CRED_ID:?}"
name=${AAP_EE_NAME:-global}
org=${AAP_ORG_ID:-}
api="${AAP_URL%/}/api/controller/v2/execution_environments/"

aap() {
  local out
  if ! out=$(curl --silent --show-error --fail-with-body \
    -H "Authorization: Bearer $AAP_TOKEN" \
    -H "Content-Type: application/json" "$@"); then
    echo "ERROR: AAP API call failed: ${out:-<no response body>}" >&2
    return 1
  fi
  printf '%s' "$out"
}

payload=$(jq -n \
  --arg name "$name" \
  --arg image "$image" \
  --argjson credential "$AAP_REG_CRED_ID" \
  --arg org "$org" \
  '{name: $name, image: $image, pull: "missing", credential: $credential,
    organization: (if $org == "" then null else ($org | tonumber) end),
    description: "Managed by ee-internal CI - do not edit by hand"}')

query=(--data-urlencode "name=$name")
if [[ -n $org ]]; then query+=(--data-urlencode "organization=$org")
else query+=(--data-urlencode "organization__isnull=true"); fi

existing=$(aap --get "${query[@]}" "$api")
count=$(jq -r '.count' <<<"$existing")

case $count in
  0)
    echo "Creating execution environment '$name' -> $image"
    result=$(aap -X POST --data "$payload" "$api")
    ;;
  1)
    id=$(jq -r '.results[0].id' <<<"$existing")
    old=$(jq -r '.results[0].image' <<<"$existing")
    echo "Updating execution environment '$name' (id $id): $old -> $image"
    result=$(aap -X PATCH --data "$payload" "${api}${id}/")
    ;;
  *)
    echo "ERROR: $count execution environments named '$name' match - refusing to guess" >&2
    exit 1
    ;;
esac

jq '{id, name, image, pull, credential, organization}' <<<"$result"
[[ $(jq -r '.image' <<<"$result") == "$image" ]] || { echo "ERROR: AAP did not store the new image" >&2; exit 1; }
echo "OK"
