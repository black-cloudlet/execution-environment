# ee-deps: dependency execution environment (connected side)

ee-deps is the heavy layer of the AAP execution environments: the AAP 2.7
`ee-minimal-rhel9` base plus public/certified collections and their Python
and RPM dependencies. Those dependencies are baked in by `ansible-builder`, so
jobs no longer fail with *"boto3/botocore required"*.

It is built, scanned and signed on the connected GitLab, then exported as a
transfer bundle and imported into the air-gapped Quay. There it becomes the
base image of **ee-internal**.

> **Never put internal content in this repo.** No internal collections, CA
> certificates, hostnames or credentials. Those belong in ee-internal.

## Files

| File | Purpose |
|------|---------|
| `execution-environment.yml` | ansible-builder v3 definition. Base image pinned by digest; `package_manager_path: /usr/bin/microdnf` |
| `requirements.yml` | Collections: `amazon.aws`, `community.aws` |
| `requirements.txt` | Extra pip packages only. `bindep` is required by ee-internal's offline build. boto3/botocore are **not** listed; they are introspected from amazon.aws |
| `bindep.txt` | RPMs (`pkg [platform:rpm]`) |
| `.trivyignore` | Accepted CVEs, with justification |
| `scripts/` | `base-image.sh` (digest-pin check), `smoke-test.sh`, `check-no-secrets.sh`, `export-bundle.sh` |
| `ci-tools/Containerfile` | CI tools image: rootless buildah, ansible-builder, skopeo, cosign v2, trivy, jq |

## Pipeline

| Trigger | Jobs | Result |
|---------|------|--------|
| Merge request | create → build (smoke test, secret check, Trivy) | nothing pushed |
| Default branch | … → push `:<short-sha>` → sign | signed image |
| Semver tag `vX.Y.Z` | … → push `:<tag>` (refused if it already exists) → sign → **export-bundle** | signed image + transfer bundle in job artifacts |

Inside `build`, the image is smoke-tested, checked for secrets and scanned
(it fails on any `CRITICAL` CVE not in `.trivyignore`). Only then is it
pushed. All of this happens in one job because the image lives only in that
pod's storage. Splitting the steps would mean pushing unscanned images or
passing a ~1 GB artifact between jobs.

Smoke test (`scripts/smoke-test.sh`):

- `ansible --version`
- `ansible-galaxy collection list`, failing if a collection in `EXPECTED_COLLECTIONS` is missing
- `python3 -c "import boto3, botocore; ..."`
- the same import with ansible-core's own interpreter (`ansible_playbook_python`)
- `amazon.aws.aws_caller_info` against a closed local port, failing if the module reports missing boto3/botocore

## One-time setup

### 1. Base image digest

```bash
skopeo inspect --format '{{.Digest}}' \
  docker://registry.redhat.io/ansible-automation-platform-27/ee-minimal-rhel9:latest
```

Put the digest into `images.base_image.name`. CI rejects the all-zero
placeholder and any reference that isn't digest-pinned. If
`ansible --version` in the base reports a Python other than
`/usr/bin/python3`, set `dependencies.python_interpreter` as described in the
file comment.

### 2. Cosign key pair

```bash
cosign generate-key-pair
```

- `cosign.key` goes into CI variable `COSIGN_PRIVATE_KEY` (type **File**,
  protected), with its password in `COSIGN_PASSWORD` (masked, protected).
- `cosign.pub` goes into `COSIGN_PUBLIC_KEY` (type File) here **and** in
  ee-internal. Carry it across the gap separately from any bundle (see
  "Import" below).

Signing uses `--tlog-upload=false` and verification uses
`--insecure-ignore-tlog=true`. Nothing goes to the public Rekor log, and
signatures verify offline inside the air gap.

### 3. CI/CD variables

| Variable | Notes |
|----------|-------|
| `REGISTRY` | connected Quay host |
| `REGISTRY_USER` / `REGISTRY_PASSWORD` | robot account with push access to `ee/ee-deps` and `ee/ee-ci-tools` |
| `RH_REGISTRY_USER` / `RH_REGISTRY_PASSWORD` | registry.redhat.io service account |
| `COSIGN_PRIVATE_KEY`, `COSIGN_PASSWORD`, `COSIGN_PUBLIC_KEY` | see above |
| `CI_TOOLS_IMAGE` | digest-pinned tools image (step 4) |
| `RH_AUTOMATION_HUB_TOKEN` | *optional.* console.redhat.com offline token. When set, collections come from certified/validated content first, then Galaxy |
| `TRIVY_IGNORE_UNFIXED` | *optional.* `"true"` ignores CVEs that have no fix yet |

Protect the default branch and `v*` tags, and mark the signing variables as
protected.

### 4. CI tools image

Every job except `ci-tools` runs in `$CI_TOOLS_IMAGE`. To bootstrap:

1. Run the manual `ci-tools` job on the default branch. It runs
   automatically whenever `ci-tools/` changes.
2. Set `CI_TOOLS_IMAGE` to the `CI_TOOLS_IMAGE=…@sha256:…` line it prints.
3. Carry the tools image across the gap once, and again whenever it changes:

   ```bash
   skopeo copy --preserve-digests docker://quay.example.com/ee/ee-ci-tools@sha256:<digest> oci-archive:ee-ci-tools.oci.tar
   ```

   ```bash
   skopeo copy --preserve-digests oci-archive:ee-ci-tools.oci.tar docker://quay.example.internal/ee/ee-ci-tools:<short-sha>
   ```

### 5. Runner requirements

Use the Kubernetes executor with rootless buildah, never privileged:

- Run the build container as uid 1000 (the tools image's `build` user, which
  has subuid/subgid ranges).
- `STORAGE_DRIVER=vfs` and `BUILDAH_ISOLATION=chroot` are set in
  `.gitlab-ci.yml`.
- vfs copies whole layers, so request roughly **20 Gi of ephemeral storage**
  for build pods.

The same applies on OpenShift; see ee-internal's README for an example runner
config with `pipelines-scc`.

## Building locally

```bash
ansible-builder create -v 3 -f execution-environment.yml -c context --output-filename Containerfile
```

```bash
podman build -f context/Containerfile -t ee-deps:dev context
```

`scripts/smoke-test.sh` and `scripts/check-no-secrets.sh` work against buildah
storage. Podman shares that storage when run as the same user.

## Releasing

1. Merge the change (collection bump, base digest bump, …). The default
   branch publishes `:<short-sha>`.
2. Tag it with semver: `git tag v1.4.0 && git push origin v1.4.0`.
3. The tag pipeline pushes `ee-deps:v1.4.0`, signs it and runs
   `export-bundle`. Download that job's artifacts: `ee-deps-v1.4.0.zip`.

Release tags are immutable: a pipeline refuses to push an existing tag. Also
enable tag immutability for the repository in Quay.

> The bundle is roughly the image's compressed size (several hundred MB).
> Raise **Settings → CI/CD → Maximum artifacts size** for this project, or the
> instance limit, accordingly.

## Transfer bundle

`bundle/` in the `export-bundle` artifacts:

| File | Content |
|------|---------|
| `ee-deps-<tag>.oci.tar` | image as an oci-archive (digest preserved) |
| `ee-deps-<tag>.sig.oci.tar` | cosign signature artifact (`sha256-<hex>.sig`) |
| `ee-deps-<tag>.digest` | manifest digest |
| `ee-deps-<tag>.sbom.cdx.json` | CycloneDX SBOM (Trivy) |
| `ee-deps-<tag>.source` | source tag and digest reference |
| `SHA256SUMS`, `SHA256SUMS.sig` | checksums of all files, cosign blob signature over them |

Move the bundle across the gap with your approved transfer mechanism (data
diode, scanned media, …). The checksums and signatures make it
tamper-evident in transit.

## Import (air-gapped side)

Run these steps from an air-gapped workstation or runner that has `skopeo`,
`cosign` and `jq` (the CI tools image has all three). Use the script
`scripts/import-bundle.sh` from the **ee-internal** repo.

```bash
skopeo login quay.example.internal
```

```bash
export COSIGN_PUBLIC_KEY=/path/to/trusted/cosign.pub
```

```bash
ee-internal/scripts/import-bundle.sh ./bundle quay.example.internal/ee/ee-deps ee-internal/execution-environment.yml
```

The script:

1. checks `SHA256SUMS` and verifies `SHA256SUMS.sig` with your trusted
   `cosign.pub`. Never use a key that came inside the bundle.
2. runs `skopeo copy --preserve-digests` for the image into
   `quay…/ee/ee-deps:<tag>`, and for the signature into
   `quay…/ee/ee-deps:sha256-<hex>.sig`.
3. confirms the digest in Quay equals `ee-deps-<tag>.digest`.
4. runs `cosign verify --key cosign.pub --insecure-ignore-tlog=true quay…/ee/ee-deps@<digest>`.
5. rewrites `images.base_image.name` in ee-internal's
   `execution-environment.yml` to `quay…/ee/ee-deps@<digest>`.

Then open an **MR in ee-internal** with that one-line digest bump. Its pipeline
re-verifies the signature and builds and tests the internal layer.

The same procedure, done by hand:

```bash
sha256sum --check SHA256SUMS
```

```bash
cosign verify-blob --key cosign.pub --insecure-ignore-tlog=true --signature SHA256SUMS.sig SHA256SUMS
```

```bash
skopeo copy --preserve-digests oci-archive:ee-deps-v1.4.0.oci.tar docker://quay.example.internal/ee/ee-deps:v1.4.0
```

```bash
skopeo copy --preserve-digests oci-archive:ee-deps-v1.4.0.sig.oci.tar "docker://quay.example.internal/ee/ee-deps:$(sed 's/:/-/' ee-deps-v1.4.0.digest).sig"
```

```bash
cosign verify --key cosign.pub --insecure-ignore-tlog=true "quay.example.internal/ee/ee-deps@$(cat ee-deps-v1.4.0.digest)"
```

## Maintenance

- **Base image:** bump the digest regularly to pick up RHEL errata. Scheduled
  default-branch pipelines rebuild and rescan.
- **Collections:** pin exact versions in `requirements.yml` once a build is
  good. Take them from the smoke-test log.
- **Tools:** bump the digests in `ci-tools/Containerfile`. Keep cosign on
  v2.x unless you also adapt the signing flags.
