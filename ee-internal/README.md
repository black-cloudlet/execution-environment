# ee-internal: internal execution environment (air-gapped side)

This folder is the content of the **air-gapped GitLab project** and is
built by its `.gitlab-ci.yml`. The connected side (ee-deps) is built by
GitHub Actions.

ee-internal is a thin layer on top of the imported, signature-verified
**ee-deps** image. It adds **only internal collections** from Private
Automation Hub (PAH) and is the image registered in AAP as the execution
environment **`global`**.

Everything heavy (Python packages, RPMs, public/certified collections) is
already in ee-deps. The build therefore reaches only two services:

- **Quay**, to pull the base image and push the result
- **PAH**, to download internal collections

## Files

| File | Purpose |
|------|---------|
| `execution-environment.yml` | ansible-builder v3. `base_image` is the internal Quay copy of ee-deps, pinned by digest. Galaxy dependencies only. Has a pip no-index guard |
| `requirements.yml` | Internal collections from PAH (placeholder `acme.platform`) |
| `files/ansible.cfg` | `server_list = automation_hub` pointing at PAH. No token |
| `files/certs/` | Internal CA certificates (`*.crt` / `*.pem`) |
| `scripts/verify-base.sh` | Verifies the base image's cosign signature |
| `scripts/import-bundle.sh` | Imports a transfer bundle (ee-deps or ee-ci-tools, both from GitHub Actions) into Quay. For ee-deps it also bumps the digest |
| `scripts/register-ee.sh` | Creates or updates the EE in AAP |
| `scripts/smoke-test.sh`, `check-no-secrets.sh`, `base-image.sh` | Identical copies of the ee-deps scripts |
| `docs/aap-changes.md` | One-time changes to projects, job templates and inventory sources in AAP |

## How the PAH token stays out of the image

1. CI passes it as `--build-arg ANSIBLE_GALAXY_SERVER_AUTOMATION_HUB_TOKEN=$PAH_TOKEN`.
2. It is declared as an `ARG`, never `ENV`, in `prepend_galaxy`. That puts it
   only in ansible-builder's intermediate *galaxy* stage. `files/ansible.cfg`
   is copied into the same stage only.
3. The final stage is built from *base* and copies just
   `/usr/share/ansible` from the galaxy stage. The token, the config and the
   ARG are not in the final image or its history.
4. `scripts/check-no-secrets.sh` enforces this on every build. It fails if
   the values of `PAH_TOKEN`, `REGISTRY_PASSWORD` or `AAP_TOKEN` appear in the
   image config or history (`buildah inspect`, the same data as
   `podman history`), or under `/etc`, `/root`, `/home`, `/runner`, `/tmp`,
   `/opt` or `/usr/share/ansible`. It also fails on any `*TOKEN*=…` or
   `*PASSWORD*=…` assignment in the image history.

To check by hand:

```bash
podman history --no-trunc quay.example.internal/ee/ee-internal:v1.4.0 | grep -iE 'token|password' || echo clean
```

## Why the build needs no PyPI or RPM repos

ansible-builder still runs its builder stage. It introspects every collection
in the image, including amazon.aws from the base, and calls pip and bindep.
Because ee-deps already contains all of those packages, including `bindep`
itself, pip only reports *already satisfied*.

The no-index guard makes this a hard rule. `/etc/pip.conf` with
`no-index = true` exists during the build and is removed at the end. If an
internal collection pulls in a Python package that isn't in ee-deps, the
build **fails immediately** instead of hanging on network timeouts. Add that
dependency to ee-deps, release it, and import it.

If an internal collection depends on another collection, that collection must
already be in ee-deps. Installed collections satisfy dependencies without
contacting PAH.

## Pipeline

| Trigger | Jobs | Result |
|---------|------|--------|
| Merge request | verify-base → create → build (smoke test, secret check) | nothing pushed |
| Default branch | … → push `:<short-sha>` | |
| Semver tag `vX.Y.Z` | … → push `:<tag>` (refused if it already exists) → **register-ee** (manual) | EE `global` in AAP points at `:<tag>` |

- `verify-base` runs `cosign verify --key $COSIGN_PUBLIC_KEY --insecure-ignore-tlog=true <base>@<digest>`
  offline. The build stops if the base image wasn't signed by ee-deps.
- The smoke test is the same as in ee-deps: ansible, the collection list
  (`EXPECTED_COLLECTIONS`), the boto3/botocore imports and the amazon.aws
  module check.

## CI/CD variables

| Variable | Notes |
|----------|-------|
| `REGISTRY` | internal Quay host |
| `REGISTRY_USER` / `REGISTRY_PASSWORD` | Quay robot account: pull `ee/ee-deps` and `ee/ee-ci-tools`, push `ee/ee-internal` (masked) |
| `PAH_TOKEN` | PAH API token with read access to the internal namespace (masked) |
| `COSIGN_PUBLIC_KEY` | `cosign.pub` from ee-deps (type **File**) |
| `CI_TOOLS_IMAGE` | internal copy of the tools image, by digest. Built by the `ci-tools` GitHub workflow and imported with `scripts/import-bundle.sh` |
| `AAP_URL` | e.g. `https://aap.example.internal` (gateway). `/api/controller/v2/` is appended |
| `AAP_TOKEN` | AAP OAuth token allowed to manage execution environments (masked, **protected**) |
| `AAP_REG_CRED_ID` | ID of the AAP *Container Registry* credential for Quay |
| `AAP_ORG_ID` | organization ID of the EE. Leave it empty for an org-less (global) EE |

`AAP_EE_NAME` defaults to `global` in `.gitlab-ci.yml`.

## Runner (OpenShift, Kubernetes executor)

Builds run as rootless buildah (`STORAGE_DRIVER=vfs`,
`BUILDAH_ISOLATION=chroot`). The build service account needs
**pipelines-scc** (OpenShift Pipelines) or **anyuid**, never `privileged`.

```bash
oc create serviceaccount ee-builder -n gitlab-runner
```

```bash
oc adm policy add-scc-to-user pipelines-scc -z ee-builder -n gitlab-runner
```

Example `config.toml` excerpt:

```toml
[[runners]]
  executor = "kubernetes"
  [runners.kubernetes]
    namespace = "gitlab-runner"
    service_account = "ee-builder"
    privileged = false
    # newuidmap/newgidmap rely on file capabilities. If buildah reports
    # "insufficient UIDs or GIDs" or newuidmap errors, allow privilege
    # escalation. The pod is still not privileged.
    allow_privilege_escalation = true
    ephemeral_storage_request = "20Gi"
    [runners.kubernetes.build_container_security_context]
      run_as_user = 1000
      run_as_group = 1000
```

Egress for build pods, for example via an `EgressFirewall` or
`NetworkPolicy`: allow Quay and PAH, plus GitLab itself (job traces,
artifacts) and AAP for `register-ee`. Deny everything else. An MR pipeline
going green under that policy proves the build needs no other network access.

## Updating the base image (new ee-deps release)

1. Import the bundle and bump the digest. See the ee-deps README, section
   "Import":

   ```bash
   scripts/import-bundle.sh ./bundle quay.example.internal/ee/ee-deps execution-environment.yml
   ```

2. Commit the one-line digest change, then open an MR. The MR pipeline
   verifies the signature, builds and smoke-tests the image.
3. Merge it, then tag a release (`vX.Y.Z`).

## Releasing and registering in AAP

1. Push a semver tag. The pipeline pushes `ee-internal:<tag>`.
2. Run the manual **register-ee** job on the tag pipeline. It looks up the
   EE named `global` (in `AAP_ORG_ID`, or org-less if empty):
   - **found:** it PATCHes `image=<registry>/ee/ee-internal:<tag>`,
     `pull=missing` and `credential=$AAP_REG_CRED_ID`.
   - **not found:** it creates the EE with those values.

   The EE is updated in place, so job templates and inventory sources keep
   pointing at the same EE. `pull=missing` is safe because tags are
   immutable: a new tag is always pulled on first use.
3. **Rollback:** re-run `register-ee` on the previous tag's pipeline.

Protect the `aap` environment (**Settings → CI/CD → Protected environments**)
to restrict who can run `register-ee`.

For the one-time changes to projects, job templates and inventory sources,
see [docs/aap-changes.md](docs/aap-changes.md).
