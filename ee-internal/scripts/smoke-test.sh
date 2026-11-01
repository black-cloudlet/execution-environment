#!/usr/bin/env bash
# Smoke-test an execution environment image held in local buildah storage.
#
# Usage: smoke-test.sh IMAGE [COLLECTION ...]
#   COLLECTION  FQCNs that must be present (e.g. amazon.aws community.aws)
#
# Checks:
#   1. ansible --version
#   2. ansible-galaxy collection list (+ every expected collection present)
#   3. boto3/botocore import with `python3`, the interpreter discovered for an
#      explicit localhost
#   4. boto3/botocore import with ansible-core's own interpreter
#      (ansible_playbook_python, used for implicit localhost)
#   5. amazon.aws.aws_caller_info no longer fails with "boto3/botocore
#      required". This is the failure seen in AAP. The call targets a closed
#      local port, so no network is used.
set -euo pipefail

image=${1:?usage: smoke-test.sh IMAGE [COLLECTION ...]}
shift
expected=("$@")

section() { printf '\n\033[1;34m--- %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31mFAIL: %s\033[0m\n' "$*" >&2; exit 1; }

ctr=$(buildah from --pull=never "$image")
trap 'buildah rm "$ctr" >/dev/null 2>&1 || true' EXIT

# Run as the image's default user (as AAP does). Without the EE entrypoint
# that UID has no passwd entry, so give it a writable HOME.
run() { buildah run "$ctr" -- env HOME=/tmp "$@"; }

section "ansible --version"
version_out=$(run ansible --version)
printf '%s\n' "$version_out"

section "ansible-galaxy collection list"
collections=$(run ansible-galaxy collection list 2>&1)
printf '%s\n' "$collections"
missing=()
for c in "${expected[@]}"; do
  grep -Eq "^${c//./\\.}[[:space:]]" <<<"$collections" || missing+=("$c")
done
((${#missing[@]} == 0)) || fail "collections missing from image: ${missing[*]}"

check_boto='import boto3, botocore; print("boto3", boto3.__version__, "botocore", botocore.__version__)'

section "boto3/botocore via python3"
run python3 -c "$check_boto" || fail "python3 cannot import boto3/botocore"

section "boto3/botocore via ansible-core's interpreter"
# e.g. "  python version = 3.12.5 (main, ...) [GCC ...] (/usr/bin/python3.12)"
ansible_python=$(sed -n 's/^ *python version = .*(\(\/[^)]*\))$/\1/p' <<<"$version_out")
[[ -n $ansible_python ]] || fail "could not determine ansible-core's python from 'ansible --version'"
echo "ansible-core python: $ansible_python"
run "$ansible_python" -c "$check_boto" || fail "$ansible_python cannot import boto3/botocore"

section "amazon.aws module dependency check (no network)"
module_out=$(run env \
  AWS_ACCESS_KEY_ID=smoke-test AWS_SECRET_ACCESS_KEY=smoke-test \
  AWS_REGION=us-east-1 AWS_MAX_ATTEMPTS=1 AWS_EC2_METADATA_DISABLED=true \
  ANSIBLE_LOCALHOST_WARNING=false \
  ansible localhost -m amazon.aws.aws_caller_info -a endpoint_url=http://127.0.0.1:9 2>&1 || true)
printf '%s\n' "$module_out"
grep -q '^localhost |' <<<"$module_out" || fail "amazon.aws.aws_caller_info did not run"
if grep -Eqi 'required python library|(boto3|botocore).{0,20}required|requires? (boto3|botocore)' <<<"$module_out"; then
  fail "amazon.aws reports missing boto3/botocore"
fi
echo "OK: module loaded its AWS SDK (an endpoint connection error is expected here)"

section "smoke test passed: $image"
