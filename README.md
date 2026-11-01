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

## Setup

1. Put the base image digest into `execution-environment.yml`:

   ```bash
   skopeo inspect --format '{{.Digest}}' docker://registry.redhat.io/ansible-automation-platform-27/ee-minimal-rhel9:latest
   ```

2. Add the repository secrets `RH_REGISTRY_USER` and
   `RH_REGISTRY_PASSWORD`. Use a registry.redhat.io service account.

## What the workflow does

| Event | Result |
|-------|--------|
| Pull request | build + smoke test |
| Push to `main` | … + push `ghcr.io/<owner>/ansible-ee:<short-sha>` |
| Tag `v1.2.3` | … + push `:v1.2.3`, plus artifact `ansible-ee-v1.2.3` (image `.tar` + `.sha256`) |

The smoke test runs `ansible --version`, `ansible-galaxy collection list`, and
`python3 -c "import boto3, botocore"`.

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
