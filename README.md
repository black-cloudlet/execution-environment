# Ansible execution environments

This repo builds the execution environments (EEs) for our AAP, one image per
ansible-core version, with `ansible-builder`.

**Approach:** images are built **outside** the air-gapped network, on GitHub
Actions, and then **mirrored** into the internal registry. Nothing is built
inside the air gap. Building outside means the base images, collections,
Python packages and tools always come from their current upstream sources,
not from old internal mirrors. The air gap only receives finished,
tested images.

```
GitHub Actions                 ghcr.io/<owner>/ansible-ee    air-gapped network
build + test per version  ──►  :2.20, :2.20.10-42, ...  ──►  internal registry ──► AAP
(every merge to main)          + .tar artifact per run       (mirrored)
```

| Path | What goes in it |
|------|-----------------|
| `ee/<version>/execution-environment.yml` | ansible-builder definition for one ansible-core version |
| `ee/<version>/requirements.yml` | collections, at versions that support that ansible-core |
| `requirements.txt` | extra pip packages, shared by all versions |
| `bindep.txt` | RPMs, shared by all versions |
| `.github/workflows/build-ee.yml` | builds, tests and publishes every version |
| `.github/check_collections.py` | smoke-test check that every collection supports the image's ansible-core |

## Versions

| Folder | ansible-core | Base image | Use it for |
|--------|--------------|------------|------------|
| `ee/2.20/` | 2.20 | `ee-minimal-rhel9:2.20-<build>` | managed hosts with Python 3.9+ (RHEL 9, …) |
| `ee/2.16/` | 2.16 | `ee-minimal-rhel9:2.16-<build>` | **RHEL 8** hosts |

The base images are Red Hat's AAP 2.7 minimal EEs
(`registry.redhat.io/ansible-automation-platform-27/ee-minimal-rhel9`), the
build for each ansible-core line.

**Why more than one version:** ansible-core runs its modules with the managed
host's Python. RHEL 8's system Python is 3.6, and 2.16 is the last
ansible-core that supports it. Newer versions fail there with
`SyntaxError: future feature annotations is not defined`. Installing a newer
Python on the host doesn't help: the `dnf` and `rpm` modules still need the
system Python 3.6.

**Add a version** (e.g. to try 2.21 before switching):
1. Copy `ee/2.20/` to `ee/2.21/`.
2. Set `ansible_core.package_pip: ansible-core==2.21.*` and the matching
   Red Hat base tag.
3. Open a PR.

CI builds every `ee/<version>/` folder automatically. If a collection doesn't
support the new version, the smoke test names it, and you pin it in that
folder's `requirements.yml`.

**Remove a version** (e.g. when the RHEL 8 hosts are retired): delete its
folder. It stops being built; images already published stay.

Keep the `execution-environment.yml` files in sync except for the base tag
and the ansible-core pin.

## What's in the images

- **Collections:** listed in `ee/<version>/requirements.yml`, covering AWS,
  VMware, containers / Kubernetes, Windows, Linux, databases and Vault.
  Their Python and system dependencies are added by `ansible-builder`
  automatically.
- **Extra Python packages:** `requirements.txt`.
- **RPMs:** `bindep.txt`. Only UBI 9 packages are available; GitHub runners
  have no RHEL subscription.
- **Command-line tools,** besides `ansible`:
  - `jq` and `yq` (the jq-syntax yq, also `xq` and `tomlq`). Python can use
    `import jq`.
  - `helm` and `argocd`, copied from digest-pinned upstream images
    (`append_final`).
  - `oc` from Red Hat's `ose-cli-rhel9:v4.20`, which follows the latest
    4.20.z. Change it when the cluster is upgraded.

**To change what's in the images,** edit those files in a PR:
- **A collection** goes in each `ee/<version>/requirements.yml`.
- **A pip package** goes in `requirements.txt`.
- **An RPM** goes in `bindep.txt`.
- **A CLI tool** is a `COPY --from=<image>` line in each
  `execution-environment.yml`.

Pin a collection only when the newest release doesn't support that
ansible-core. `ansible-galaxy` ignores that when choosing versions; the
smoke test catches it.

## Setup

1. Add the secrets `RH_REGISTRY_USER` and `RH_REGISTRY_PASSWORD`, for a
   registry.redhat.io service account. They can be repository or
   organization secrets. Organization secrets must allow this repository.

2. The base image in each `ee/<version>/execution-environment.yml` is
   pinned to a Red Hat build tag (`<version>-<build>`). Red Hat publishes a
   new tag per build, so a tag never changes. CI adds a note to the run when
   a newer build of the same line exists. To update, set the newer tag in
   that folder. To list the tags:

   ```bash
   skopeo list-tags docker://registry.redhat.io/ansible-automation-platform-27/ee-minimal-rhel9
   ```

## How releases work

**Every merge to `main` is a release.** There are no git tags to create.
Every push to any other branch is built, tested and published too, under
tags that carry the branch name, so a change can be tried in AAP before it
is merged.

| Build | Moving tag | Fixed tag (never changes) |
|-------|------------|---------------------------|
| `main` | `ansible-ee:2.20` | `ansible-ee:2.20.10-42`. **Use this one in AAP** |
| branch `feature/vmware` | `ansible-ee:2.20-feature-vmware` | `ansible-ee:2.20.10-feature-vmware-3` |

All tags are on `ghcr.io/<owner>/ansible-ee`. Only `main` builds also upload
an air-gap artifact.

- **The number counts that branch's builds:** `-42` is the 42nd build of
  `main`, and `-3` the 3rd build of `feature/vmware`. The workflow run shows
  the commit.
- **Both versions from one build share it:** `2.20.10-42` and `2.16.19-42`.
- **A re-run** of a failed build gets `-42.2` instead of overwriting.
- **Branch names are cleaned:** characters that tags don't allow become `-`.
- **Pull requests show the result** of the push build of their branch.

The smoke test checks, for every version:
- the ansible-core version
- that every collection supports that version
- the Python imports of the bundled libraries
- every CLI tool

## Mirroring into the air-gapped registry

Mirror only the fixed tags (`2.20.10-42`), never the moving ones, so AAP
always knows exactly which image it runs.

**From GHCR**, on a host that can reach both GHCR and the internal registry:

```bash
skopeo copy docker://ghcr.io/<owner>/ansible-ee:2.20.10-42 docker://quay.example.internal/ee/ansible-ee:2.20.10-42
```

**From the artifact**, when the image has to be carried across as a file.
Each run uploads `ansible-ee-<tag>` (image `.tar` + `.sha256`), kept for
30 days. Download it from the workflow run, carry it across, then:

```bash
sha256sum -c ansible-ee-2.20.10-42.tar.sha256
```

```bash
skopeo copy oci-archive:ansible-ee-2.20.10-42.tar docker://quay.example.internal/ee/ansible-ee:2.20.10-42
```

## Using the images in AAP

1. Open **Execution Environments** and create one EE per version, named by
   the hosts it is for:

   | AAP execution environment | Image |
   |---------------------------|-------|
   | `RHEL 9+ (ansible-core 2.20)` | `quay.example.internal/ee/ansible-ee:2.20.10-42` |
   | `RHEL 8 (ansible-core 2.16)` | `quay.example.internal/ee/ansible-ee:2.16.19-42` |

   - pull: *Only pull the image if not present*. The tags never change.
   - registry credential: your internal registry credential

   To upgrade, mirror the newer tag and change the image.

2. Select the matching EE on the **job templates** and on the **inventory
   sources**. Inventory plugins such as `aws_ec2` or `vmware_vm_inventory`
   run in the inventory source's EE, not the job template's.

3. Take collections from the EE, not from a project's
   `collections/requirements.yml`. Collections installed at project sync
   override the EE's versions but don't get their Python dependencies.

4. If `localhost` is listed explicitly in an inventory, give it
   `ansible_connection: local` and
   `ansible_python_interpreter: "{{ ansible_playbook_python }}"`, so
   localhost tasks use the EE's Python and its libraries.
