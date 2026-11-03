# Ansible execution environments for AAP

AAP jobs failed with *"boto3/botocore required"* because `amazon.aws` was
installed from the project's `collections/requirements.yml` at sync time.
That way its Python dependencies never got installed.

This repo builds execution environments (EEs) with `ansible-builder`. The
collections **and** their Python dependencies are baked into the image. There
is one image per ansible-core version.

| Path | What goes in it |
|------|-----------------|
| `ee/<version>/execution-environment.yml` | ansible-builder config for one ansible-core version (AAP 2.7 `ee-minimal-rhel9` base) |
| `ee/<version>/requirements.yml` | collections, at versions that support that ansible-core |
| `requirements.txt` | extra pip packages, shared by all versions (boto3/botocore are added automatically) |
| `bindep.txt` | RPMs, shared by all versions |
| `.github/workflows/build-ee.yml` | build, test, publish every version |
| `.github/check_collections.py` | smoke-test check that every collection supports the image's ansible-core |

## Versions

| Folder | ansible-core | Use it for |
|--------|--------------|------------|
| `ee/2.20/` | 2.20 | managed hosts with Python 3.9+ (RHEL 9, …) |
| `ee/2.16/` | 2.16 | **RHEL 8** hosts. Their system Python is 3.6, and 2.16 is the last ansible-core that supports it |

On RHEL 8 hosts, newer ansible-core fails with
`SyntaxError: future feature annotations is not defined`. Installing a newer
Python on the host doesn't fix it: `dnf` and `rpm` modules still need the
system Python 3.6.

**Add a version** (e.g. to try 2.21 before switching):
1. Copy `ee/2.20/` to `ee/2.21/`.
2. Set `ansible_core.package_pip: ansible-core==2.21.*` in the new folder.
3. Open a PR.

CI builds every `ee/<version>/` folder automatically. If a collection doesn't
support the new version, the smoke test names it, and you pin it in that
folder's `requirements.yml`.

**Remove a version** (e.g. when the RHEL 8 hosts are retired): delete its
folder. It stops being built; images already published stay.

Keep the `execution-environment.yml` files in sync except for the
ansible-core pin. Only the collection versions should differ between folders.

Command-line tools in every image, besides `ansible`:
- `jq` and `yq` (the jq-syntax yq, also `xq` and `tomlq`). Python can use
  `import jq`.
- `helm` 3.22.1 and `argocd` v3.5.6, copied from digest-pinned upstream
  images (`append_final`). To bump one, change its tag and digest there.
- `oc` for OpenShift 4.20, from Red Hat's
  `registry.redhat.io/openshift4/ose-cli-rhel9:v4.20`. That tag follows the
  latest 4.20.z. Change it when the cluster is upgraded.

## Setup

1. Add the secrets `RH_REGISTRY_USER` and `RH_REGISTRY_PASSWORD`, for a
   registry.redhat.io service account. They can be repository or
   organization secrets. Organization secrets must allow this repository.

2. The base image in each `ee/<version>/execution-environment.yml` is
   pinned to a Red Hat build tag, e.g. `ee-minimal-rhel9:2.20-1793110779`.
   Red Hat publishes a new tag per build, so a tag never changes. CI adds a
   note to the run when a newer build exists. To update, set the new tag
   in every `ee/*/` folder. To list the tags:

   ```bash
   skopeo list-tags docker://registry.redhat.io/ansible-automation-platform-27/ee-minimal-rhel9
   ```

## How releases work

**Every merge to `main` is a release.** There are no git tags to create.

| Event | Result |
|-------|--------|
| Pull request | build + smoke test every version, nothing published |
| Merge to `main` (or a manual run on `main`) | … + push and an air-gap artifact for every version |

For each version, a merge to `main` publishes:

| Tag | Example | Changes? |
|-----|---------|----------|
| `<major.minor>` | `ghcr.io/<owner>/ansible-ee:2.20` | moves to the newest build |
| `<ansible-core>-<date>-<commit>` | `ghcr.io/<owner>/ansible-ee:2.20.10-20261103-a1b2c3d` | never changes. **Use this one in AAP** |

The artifact `ansible-ee-2.20.10-20261103-a1b2c3d` (image `.tar` + `.sha256`)
is kept for 30 days on the workflow run.

The smoke test checks, for every version:
- the ansible-core version
- that every collection supports that version
- the boto3/botocore and other Python imports
- every CLI tool

## Use it in the air-gapped AAP

1. Download the artifact for each version you need from the merge's
   workflow run, and carry it across. Example: `ansible-ee-2.20.10-20261103-a1b2c3d`.
2. Check the file and push it to your internal registry:

   ```bash
   sha256sum -c ansible-ee-2.20.10-20261103-a1b2c3d.tar.sha256
   ```

   ```bash
   skopeo copy oci-archive:ansible-ee-2.20.10-20261103-a1b2c3d.tar docker://quay.example.internal/ee/ansible-ee:2.20.10-20261103-a1b2c3d
   ```

3. In AAP, open **Execution Environments** and create one EE per version,
   named by the hosts it is for:

   | AAP execution environment | Image |
   |---------------------------|-------|
   | `RHEL 9+ (ansible-core 2.20)` | `quay.example.internal/ee/ansible-ee:2.20.10-20261103-a1b2c3d` |
   | `RHEL 8 (ansible-core 2.16)` | `quay.example.internal/ee/ansible-ee:2.16.20-20261103-a1b2c3d` |

   - pull: *Only pull the image if not present*. The tags never change.
   - registry credential: your Quay credential

   To upgrade, change the image to the newer tag.

4. Make three AAP-side changes:
   - Remove `amazon.aws` and `community.aws` from the projects'
     `collections/requirements.yml`.
   - Select the matching EE on the **job templates** and on the
     **inventory sources**. The `aws_ec2` inventory plugin runs in the
     inventory source's EE.
   - If `localhost` is listed explicitly in an inventory, give it
     `ansible_connection: local` and
     `ansible_python_interpreter: "{{ ansible_playbook_python }}"`.

5. Re-run a job that failed before.
