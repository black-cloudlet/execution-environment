# Custom Ansible execution environments for air-gapped AAP

This repo fixes AAP jobs failing with *"boto3/botocore required"*. The cause:
`amazon.aws` was installed from each project's `collections/requirements.yml`
at sync time, so its Python dependencies were never installed. The fix is to
build execution environments in which `ansible-builder` bakes in the
collections **and** their Python and RPM dependencies.

The two layers:

| Folder | Built by | Contents |
|--------|----------|----------|
| [`ee-deps/`](ee-deps/README.md) | **GitHub Actions** in this repo (`.github/workflows/ee-deps.yml`), pushed to **GHCR** | AAP 2.7 `ee-minimal-rhel9` (by digest) + pip packages + RPMs + public/certified collections. Built, smoke-tested, Trivy-scanned, cosign-signed, exported as a transfer bundle |
| [`ee-internal/`](ee-internal/README.md) | **air-gapped GitLab** (`ee-internal/.gitlab-ci.yml`). Copy this folder into that GitLab project | Imported ee-deps (by digest, signature verified) + internal collections from PAH. Registered in AAP as EE **`global`** |

```
 GitHub (connected)                                        │ air gap │          air-gapped GitLab / Quay / AAP
 tag ee-deps-vX.Y.Z ─► build ─► smoke ─► scan ─► push GHCR ─► sign ─► bundle artifact ══► import-bundle.sh ─► internal Quay
                                                       (oci-archive, sig, digest, SBOM)          │ (verify sums, sig, digest)
                                                                                                 ▼
                                        AAP EE "global" ◄─ register-ee (manual) ◄─ tag ◄─ MR: verify-base ─► build ─► smoke
```

The `ci-tools` workflow builds the CI tools image that the air-gapped GitLab
pipeline runs in, and ships it the same way: signed bundle, then
`import-bundle.sh`.

Internal code, collections, CA certificates, hostnames and credentials exist
only in `ee-internal/`. Nothing internal is ever built on GitHub.

## Decisions

| Topic | Decision |
|-------|----------|
| AAP version | **2.7**: `registry.redhat.io/ansible-automation-platform-27/ee-minimal-rhel9` |
| CI | ee-deps and the tools image: **GitHub Actions** on GitHub-hosted `ubuntu-24.04` (rootless buildah). ee-internal: **GitLab CI** inside the air gap |
| Connected registry | **GHCR** (`ghcr.io/<owner>/ee-deps`, `…/ee-ci-tools`), pushed with `GITHUB_TOKEN` |
| EE in AAP | one EE named **`global`**, updated in place (PATCH) per release. `AAP_ORG_ID` empty = org-less EE |
| Scanner | **Trivy**: fails on CRITICAL (exceptions in `.trivyignore`), CycloneDX SBOM |
| Signing | **cosign key pair** (v2.6.1). Private key in the protected `signing` environment, public key on both sides. No Rekor upload, verified offline |
| Transfer | **oci-archive bundle** as a workflow artifact, moved by your approved mechanism |
| Dependencies | `amazon.aws`, `community.aws`. Pip: only `bindep` (needed by the offline internal build). RPMs: `git-core`, `openssh-clients` |
| Tags | ee-deps: git tag `ee-deps-vX.Y.Z` → immutable image tag `vX.Y.Z`; `main` → short SHA; PRs push nothing. ee-internal (GitLab): `vX.Y.Z` / short SHA; MRs push nothing |

## Placeholders to replace before the first run

- `ee-deps/execution-environment.yml`: the real `ee-minimal-rhel9` digest.
  The workflow rejects the all-zero placeholder.
- GitHub: secrets, variables and the `signing` environment. See the
  ee-deps README, "One-time setup".
- `ee-internal/execution-environment.yml`: base digest. `import-bundle.sh`
  writes it for you.
- `ee-internal/requirements.yml` and `EXPECTED_COLLECTIONS`: your internal
  collections, in place of `acme.platform`.
- `ee-internal/files/ansible.cfg`: the PAH URL. `files/certs/`: the internal
  CA, if needed.
- `ee-internal/.gitlab-ci.yml`: `REGISTRY`, plus the GitLab CI/CD variables
  listed in the ee-internal README.
- `ee-deps/requirements.yml`: pin exact collection versions after the first
  good build.

## Acceptance criteria

| Criterion | Where |
|-----------|-------|
| ee-deps tag → signed image + transfer bundle in job artifacts | `.github/workflows/ee-deps.yml`: `sign`, `export-bundle` (artifact `ee-deps-vX.Y.Z`) |
| ee-internal MR → green build, no network except PAH and Quay | no python/system deps, pip no-index guard, `bindep` preinstalled in ee-deps. Enforce with build-pod egress rules (ee-internal README) |
| ee-internal tag → image pushed, manual job updates EE in AAP | `ee-internal/.gitlab-ci.yml`: `build` (push), `register-ee` |
| boto3/botocore import works in both images; amazon.aws module loads | `scripts/smoke-test.sh` in both pipelines. Then re-run the failing job (see `ee-internal/docs/aap-changes.md`) |
| No secrets in image history | `scripts/check-no-secrets.sh` in both pipelines |
