# ee-deps: dependency execution environment (connected side)

ee-deps is the heavy layer of the AAP execution environments: the AAP 2.7
`ee-minimal-rhel9` base plus public/certified collections and their Python
and RPM dependencies. Those dependencies are baked in by `ansible-builder`, so
jobs no longer fail with *"boto3/botocore required"*.

It is built, scanned and signed by **GitHub Actions** and pushed to
**GHCR**, then exported as a transfer bundle and imported into the
air-gapped Quay. There it becomes the base image of **ee-internal**, which is
built by the air-gapped GitLab.

> **Never put internal content in this folder.** No internal collections, CA
> certificates, hostnames or credentials. Those belong in `ee-internal/`.

## Files

| File | Purpose |
|------|---------|
| `execution-environment.yml` | ansible-builder v3 definition. Base image pinned by digest; `package_manager_path: /usr/bin/microdnf` |
| `requirements.yml` | Collections: `amazon.aws`, `community.aws` |
| `requirements.txt` | Extra pip packages only. `bindep` is required by ee-internal's offline build. boto3/botocore are **not** listed; they are introspected from amazon.aws |
| `bindep.txt` | RPMs (`pkg [platform:rpm]`) |
| `.trivyignore` | Accepted CVEs, with justification |
| `scripts/` | `base-image.sh` (digest-pin check), `smoke-test.sh`, `check-no-secrets.sh`, `export-bundle.sh` |
| `ci-tools/Containerfile` | Tools image for the air-gapped GitLab: rootless buildah, ansible-builder, skopeo, cosign v2, trivy, jq |
| `../.github/workflows/ee-deps.yml` | The ee-deps pipeline |
| `../.github/workflows/ci-tools.yml` | Builds, signs and exports the tools image |
| `../.github/actions/setup-ee-tools/` | Installs pinned ansible-builder, cosign and trivy on the runner |

## Pipeline (`.github/workflows/ee-deps.yml`)

It runs on GitHub-hosted `ubuntu-24.04`, which already has buildah, podman
and skopeo. cosign and trivy are copied out of their digest-pinned upstream
images, so no third-party actions are involved.

| Trigger | Jobs | Result |
|---------|------|--------|
| Pull request touching `ee-deps/**` | build (create, build, smoke test, secret check, Trivy) | nothing pushed |
| Push to `main`, weekly schedule | … → push `ghcr.io/<owner>/ee-deps:<short-sha>` → sign | signed image |
| Tag `ee-deps-vX.Y.Z` | … → push `:vX.Y.Z` (refused if it already exists) → sign → **export-bundle** | signed image + transfer bundle artifact `ee-deps-vX.Y.Z` |

- **Tag prefix:** this repo also holds `ee-internal/`, so ee-deps release
  tags carry an `ee-deps-` prefix. The image tag is the bare semver
  (`v1.4.0`).
- **One build job:** the image is smoke-tested, checked for secrets and
  scanned (it fails on any `CRITICAL` CVE not in `.trivyignore`) in the same
  job. Only then is it pushed. The image exists only on that runner.
- **Artifacts:** every run uploads the SBOM and the Trivy JSON report as
  `ee-deps-reports-<tag>`.

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

Put the digest into `images.base_image.name`. The workflow rejects the
all-zero placeholder and any reference that isn't digest-pinned. If
`ansible --version` in the base reports a Python other than
`/usr/bin/python3`, set `dependencies.python_interpreter` as described in the
file comment.

### 2. Cosign key pair

```bash
cosign generate-key-pair
```

Signing uses `--tlog-upload=false` and verification uses
`--insecure-ignore-tlog=true`. Nothing goes to the public Rekor log, and
signatures verify offline inside the air gap.

### 3. Secrets, variables and the `signing` environment

In **Settings → Environments**, create the environment **`signing`**.

- Deployment branches and tags: `main` and `ee-deps-v*`.
- Optionally add required reviewers.

| Where | Name | Value |
|-------|------|-------|
| Environment `signing`, secret | `COSIGN_PRIVATE_KEY` | content of `cosign.key` |
| Environment `signing`, secret | `COSIGN_PASSWORD` | its password |
| Repository variable | `COSIGN_PUBLIC_KEY` | content of `cosign.pub` (also needed by ee-internal) |
| Repository secret | `RH_REGISTRY_USER` / `RH_REGISTRY_PASSWORD` | registry.redhat.io service account |
| Repository secret *(optional)* | `RH_AUTOMATION_HUB_TOKEN` | console.redhat.com offline token. When set, collections come from certified/validated content first, then Galaxy |
| Repository variable *(optional)* | `TRIVY_IGNORE_UNFIXED` | `true` ignores CVEs that have no fix yet |

- **GHCR:** the workflow pushes with the built-in `GITHUB_TOKEN`, so no
  registry secret is needed.
- **Protection:** add a branch protection rule for `main` and a tag
  protection rule/ruleset for `ee-deps-v*`.
- **Fork PRs:** pull requests from forks get no secrets, so their build stops
  at the registry.redhat.io login.

### 4. CI tools image (for the air-gapped GitLab)

`.github/workflows/ci-tools.yml` runs whenever `ee-deps/ci-tools/` changes,
or manually. It builds the image, pushes
`ghcr.io/<owner>/ee-ci-tools:<short-sha>`, signs it and uploads a transfer
bundle artifact `ee-ci-tools-<short-sha>`. That bundle has the same format as
ee-deps'.

Import it on the air-gapped side:

```bash
ee-internal/scripts/import-bundle.sh ./ee-ci-tools-bundle quay.example.internal/ee/ee-ci-tools
```

Then set ee-internal's `CI_TOOLS_IMAGE` GitLab variable to the printed
`…@sha256:` reference. The run summary shows it as well.

Keep the cosign/trivy digests in `ci-tools/Containerfile` and
`.github/actions/setup-ee-tools/action.yml` in sync.

## Building locally

```bash
ansible-builder create -v 3 -f execution-environment.yml -c context --output-filename Containerfile
```

```bash
buildah build -f context/Containerfile -t ee-deps:dev context
```

```bash
scripts/smoke-test.sh ee-deps:dev amazon.aws community.aws
```

## Releasing

1. Merge the change (collection bump, base digest bump, …). `main` publishes
   `:<short-sha>`.
2. Tag the release:

   ```bash
   git tag ee-deps-v1.4.0
   ```

   ```bash
   git push origin ee-deps-v1.4.0
   ```

3. The tag run pushes `ghcr.io/<owner>/ee-deps:v1.4.0`, signs it and runs
   `export-bundle`.
4. Download the artifact **`ee-deps-v1.4.0`** from the workflow run, either
   in the UI or with this command:

   ```bash
   gh run download <run-id> -n ee-deps-v1.4.0 -D bundle
   ```

Release tags are immutable: the workflow refuses to push an existing image
tag. GHCR has no tag-immutability setting, so this check, together with the
tag protection rule, is the guard. Artifacts are kept for 90 days.

## Transfer bundle

Contents of the `ee-deps-<tag>` artifact:

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
`cosign` and `jq` (the CI tools image has all three). Use
`ee-internal/scripts/import-bundle.sh`.

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
   `quay…/ee/ee-deps:sha256-<hex>.sig`. It refuses to overwrite an existing
   tag that has a different digest.
3. confirms the digest in Quay equals `ee-deps-<tag>.digest`.
4. runs `cosign verify --key cosign.pub --insecure-ignore-tlog=true quay…/ee/ee-deps@<digest>`.
5. rewrites `images.base_image.name` in ee-internal's
   `execution-environment.yml` to `quay…/ee/ee-deps@<digest>`.

Then open an **MR in the air-gapped ee-internal GitLab project** with that
one-line digest bump. Its pipeline re-verifies the signature and builds and
tests the internal layer.

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

- **Base image:** bump the digest regularly to pick up RHEL errata. The
  weekly scheduled run rebuilds and rescans `main`.
- **Collections:** pin exact versions in `requirements.yml` once a build is
  good. Take them from the smoke-test log.
- **Actions:** first-party actions are pinned to major tags. Pin them to
  commit SHAs if your policy requires it.
- **Tools:** keep cosign on v2.x unless you also adapt the signing flags.
