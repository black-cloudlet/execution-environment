# Custom Ansible execution environments for air-gapped AAP

This repo fixes AAP jobs failing with *"boto3/botocore required"*. The cause:
`amazon.aws` was installed from each project's `collections/requirements.yml`
at sync time, so its Python dependencies were never installed. The fix is to
build execution environments in which `ansible-builder` bakes in the
collections **and** their Python and RPM dependencies.

The two layers live in two folders here. Each folder is the complete content
of one GitLab project:

| Folder | GitLab | Contents |
|--------|--------|----------|
| [`ee-deps/`](ee-deps/README.md) | connected | AAP 2.7 `ee-minimal-rhel9` (by digest) + pip packages + RPMs + public/certified collections. Built, smoke-tested, Trivy-scanned, cosign-signed, exported as a transfer bundle |
| [`ee-internal/`](ee-internal/README.md) | air-gapped | Imported ee-deps (by digest, signature verified) + internal collections from PAH. Registered in AAP as EE **`global`** |

```
 connected                                   │ air gap │                      air-gapped
 ee-deps tag ─► build ─► smoke ─► scan ─► push ─► sign ─► export bundle ══► import-bundle.sh ─► internal Quay
                                                    (oci-archive, sig, digest, SBOM)        │ (verify sums, sig, digest)
                                                                                            ▼
                                     AAP EE "global" ◄─ register-ee (manual) ◄─ tag ◄─ MR: verify-base ─► build ─► smoke
```

Internal code, collections, CA certificates, hostnames and credentials exist
only in `ee-internal/`.

## Decisions

| Topic | Decision |
|-------|----------|
| AAP version | **2.7**: `registry.redhat.io/ansible-automation-platform-27/ee-minimal-rhel9` |
| EE in AAP | one EE named **`global`**, updated in place (PATCH) per release. `AAP_ORG_ID` empty = org-less EE |
| Scanner | **Trivy**: fails on CRITICAL (exceptions in `.trivyignore`), CycloneDX SBOM |
| Signing | **cosign key pair** (v2). Private key as protected CI File variable, public key on both sides. No Rekor upload, verified offline |
| Transfer | **oci-archive bundle** in the `export-bundle` job artifacts, moved by your approved mechanism |
| Dependencies | `amazon.aws`, `community.aws`. Pip: only `bindep` (needed by the offline internal build). RPMs: `git-core`, `openssh-clients` |
| Tags | semver git tag → immutable image tag. Default branch → short SHA. MRs push nothing |
| CI tooling | one tools image (`ee-deps/ci-tools/`): rootless buildah, ansible-builder 3.2.0, skopeo, cosign 2.6.1, trivy 0.76.1 |

## Placeholders to replace before the first run

- `ee-deps/execution-environment.yml`: the real `ee-minimal-rhel9` digest.
  CI rejects the all-zero placeholder.
- `ee-internal/execution-environment.yml`: base digest. `import-bundle.sh`
  writes it for you.
- `ee-internal/requirements.yml` and `EXPECTED_COLLECTIONS`: your internal
  collections, in place of `acme.platform`.
- `ee-internal/files/ansible.cfg`: the PAH URL. `files/certs/`: the internal
  CA, if needed.
- Hostnames in `.gitlab-ci.yml` (`REGISTRY`) and the CI/CD variables listed
  in each README.
- `ee-deps/requirements.yml`: pin exact collection versions after the first
  good build.

## Acceptance criteria

| Criterion | Where |
|-----------|-------|
| ee-deps tag → signed image + transfer bundle in job artifacts | `ee-deps/.gitlab-ci.yml`: `sign`, `export-bundle` |
| ee-internal MR → green build, no network except PAH and Quay | no python/system deps, pip no-index guard, `bindep` preinstalled in ee-deps. Enforce with build-pod egress rules (ee-internal README) |
| ee-internal tag → image pushed, manual job updates EE in AAP | `build` (push), `register-ee` |
| boto3/botocore import works in both images; amazon.aws module loads | `scripts/smoke-test.sh` in both pipelines. Then re-run the failing job (see `ee-internal/docs/aap-changes.md`) |
| No secrets in image history | `scripts/check-no-secrets.sh` in both pipelines |
