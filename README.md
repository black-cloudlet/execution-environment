# Ansible execution environment for AAP

AAP jobs failed with *"boto3/botocore required"* because `amazon.aws` was
installed from the project's `collections/requirements.yml` at sync time.
That way its Python dependencies never got installed.

This repo builds an execution environment (EE) with `ansible-builder`. The
collections **and** their Python dependencies are baked into the image.

| File | What goes in it |
|------|-----------------|
| `execution-environment.yml` | ansible-builder config (AAP 2.7 `ee-minimal-rhel9` base) |
| `requirements.yml` | collections |
| `requirements.txt` | extra pip packages (boto3/botocore are added automatically) |
| `bindep.txt` | RPMs |
| `.github/workflows/build-ee.yml` | build, test, push |
| `rhel8/` | second EE for RHEL 8 hosts (see below) |

## Two images

| Image | ansible-core | Use it for |
|-------|--------------|------------|
| `ansible-ee:global` | 2.20 | everything whose managed hosts have Python 3.9+ (RHEL 9, …) |
| `ansible-ee:rhel8` | 2.16 | job templates that manage **RHEL 8** hosts |

ansible-core 2.17 and newer need Python 3.9+ on managed hosts. RHEL 8's
system Python is 3.6, which only ansible-core 2.16 still supports. Without
it, jobs fail with `SyntaxError: future feature annotations is not defined`.

`rhel8/` reuses `requirements.txt` and `bindep.txt` from the repo root.
`rhel8/execution-environment.yml` is a copy of the main one plus the
ansible-core 2.16 pin, so keep the two in sync. `rhel8/requirements.yml`
holds collection versions that still support 2.16. CI fails if any installed
collection's `requires_ansible` excludes the image's ansible-core, in both
images.

Command-line tools in the image, besides `ansible`:
- `jq` and `yq` (the jq-syntax yq, also `xq` and `tomlq`). Python can use
  `import jq`.
- `helm` 3.22.1 and `argocd` v3.5.6, copied from digest-pinned upstream
  images in `execution-environment.yml` (`append_final`). To bump one, change
  its tag and digest there.
- `oc` for OpenShift 4.20, copied from Red Hat's
  `registry.redhat.io/openshift4/ose-cli-rhel9:v4.20`. That tag follows the
  latest 4.20.z. Change it when the cluster is upgraded.

## Setup

1. Add the secrets `RH_REGISTRY_USER` and `RH_REGISTRY_PASSWORD`, for a
   registry.redhat.io service account. They can be repository or
   organization secrets. Organization secrets must allow this repository.

2. Pin the base image digest in `execution-environment.yml`. If it isn't
   pinned, CI prints the current value. The repository has no `latest`
   tag, so look up the newest tag first:

   ```bash
   skopeo list-tags docker://registry.redhat.io/ansible-automation-platform-27/ee-minimal-rhel9
   ```

   ```bash
   skopeo inspect --format '{{.Digest}}' docker://registry.redhat.io/ansible-automation-platform-27/ee-minimal-rhel9:<newest-tag>
   ```

## What the workflow does

| Event | Result |
|-------|--------|
Both images are built in parallel.

| Event | Result |
|-------|--------|
| Pull request | build + smoke test |
| Push to `main` | … + push `ghcr.io/<owner>/ansible-ee:global` and `:rhel8` (overwritten by every build on `main`) |
| Tag `v1.2.3` | … + push `:v1.2.3` and `:v1.2.3-rhel8`, plus artifacts `ansible-ee-v1.2.3` and `ansible-ee-v1.2.3-rhel8` (image `.tar` + `.sha256`) |

The smoke test checks:
- the ansible-core version
- that every collection supports that version
- the boto3/botocore and other Python imports
- every CLI tool

## Use it in the air-gapped AAP

1. Download the `ansible-ee-v1.2.3` artifact from the tag's workflow run and
   carry it across.
2. Check the file and push it to your internal registry:

   ```bash
   sha256sum -c ansible-ee-v1.2.3.tar.sha256
   ```

   ```bash
   skopeo copy oci-archive:ansible-ee-v1.2.3.tar docker://quay.example.internal/ee/ansible-ee:v1.2.3
   ```

3. In AAP, open **Execution Environments** and create or edit the EE
   `global`:
   - image: `quay.example.internal/ee/ansible-ee:v1.2.3`
   - pull: *Only pull the image if not present*
   - registry credential: your Quay credential

   For RHEL 8 hosts, do the same with the `ansible-ee-v1.2.3-rhel8` artifact
   and a second EE, e.g. `global-rhel8`, with image
   `quay.example.internal/ee/ansible-ee:v1.2.3-rhel8`. Select that EE on the
   job templates that target RHEL 8 hosts.

4. Make three AAP-side changes:
   - Remove `amazon.aws` and `community.aws` from the projects'
     `collections/requirements.yml`.
   - Select the EE `global` on the **job templates** and on the
     **inventory sources**. The `aws_ec2` inventory plugin runs in the
     inventory source's EE.
   - If `localhost` is listed explicitly in an inventory, give it
     `ansible_connection: local` and
     `ansible_python_interpreter: "{{ ansible_playbook_python }}"`.

5. Re-run a job that failed before.
