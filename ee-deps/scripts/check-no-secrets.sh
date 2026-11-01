#!/usr/bin/env bash
# Fail if credentials leaked into an image held in local buildah storage.
#
# Usage: check-no-secrets.sh IMAGE [VAR_NAME ...]
#   VAR_NAME  names (not values) of environment variables holding secrets,
#             e.g. PAH_TOKEN REGISTRY_PASSWORD. Unset ones are skipped.
#
# Checks:
#   1. No "<NAME containing TOKEN/PASSWORD/SECRET>=<value>" assignment in the
#      image config or history (what `podman history` / `buildah inspect`
#      show), e.g. a build arg captured by a RUN in the final stage.
#   2. The value of each named variable does not appear in the image
#      config/history, nor in files under the usual config locations.
# Secret values are never printed.
set -euo pipefail

image=${1:?usage: check-no-secrets.sh IMAGE [VAR_NAME ...]}
shift

status=0
meta=$(buildah inspect --type image "$image")

echo "--- generic credential assignments in image config/history"
if hits=$(grep -Eo '[A-Za-z0-9_]*(TOKEN|PASSWORD|PASSWD|SECRET)[A-Za-z0-9_]*=[^[:space:]"\\]+' <<<"$meta"); then
  # shellcheck disable=SC2001 # multi-line input
  sed 's/=.*/=<redacted>/' <<<"$hits" | sort -u
  echo "FAIL: credential-looking assignments found in image metadata"
  status=1
else
  echo "none"
fi

ctr=$(buildah from --pull=never "$image")
trap 'buildah rm "$ctr" >/dev/null 2>&1 || true' EXIT

paths=(/etc /root /home /runner /tmp /opt /usr/share/ansible)
for name in "$@"; do
  value=${!name:-}
  echo "--- value of \$$name"
  if [[ -z $value ]]; then
    echo "skipped (unset)"
    continue
  fi
  if ((${#value} < 8)); then
    echo "skipped (shorter than 8 characters, too ambiguous to search for)"
    continue
  fi
  found=0
  if grep -qF -- "$value" <<<"$meta"; then
    echo "FAIL: found in image config/history"
    found=1
  fi
  # grep exits 0 on a match even if some paths are missing/unreadable.
  if buildah run --user 0:0 "$ctr" -- grep -rqsF -e "$value" "${paths[@]}"; then
    echo "FAIL: found in image filesystem (${paths[*]})"
    found=1
  fi
  if ((found)); then status=1; else echo "not found"; fi
done

exit "$status"
