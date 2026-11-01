# AAP-side changes

These are one-time changes, documented here but deliberately **not
automated**. Make them after the first `register-ee` run has created the
execution environment **`global`**.

## 1. Container Registry credential

Create (or reuse) a credential of type **Container Registry** for the
internal Quay:

- host: `quay.example.internal`
- user: a robot account with pull access to `ee/ee-internal`

Put its ID into the CI variable `AAP_REG_CRED_ID`. `register-ee` attaches it
to the EE, so execution nodes can pull the image.

## 2. Stop installing collections at project sync

Remove `amazon.aws` and `community.aws` from every project's
`collections/requirements.yml`, and delete the file if nothing is left in it.

Collections installed at project sync land in the project's own collection
path. That path **takes precedence over** the collections in the EE, but
their Python dependencies are never installed, which is the original
*"boto3/botocore required"* failure. With the collections baked into the EE,
the project copy is at best redundant and at worst a version that does not
match the EE's boto3/botocore.

Keep `collections/requirements.yml` only for collections that are genuinely
project-specific **and** have no Python or system dependencies.

## 3. Use the new EE everywhere amazon.aws runs

- **Job templates:** set *Execution Environment* = `global`.
- **Inventory sources:** set *Execution Environment* = `global` on each
  source. The `amazon.aws.aws_ec2` inventory plugin runs in the **inventory
  source's** EE, not the job template's, so an inventory sync can still fail
  with "boto3 required" while the jobs succeed.
- *Optional:* make `global` the organization's *Default Execution
  Environment*, so new templates pick it up automatically.

## 4. Explicit `localhost` in inventories

AWS modules run on the controller side, i.e. inside the EE, against
`localhost`. If an inventory lists `localhost` explicitly, set these variables
on the host:

```yaml
localhost:
  ansible_connection: local
  ansible_python_interpreter: "{{ ansible_playbook_python }}"
```

Without them, interpreter discovery may choose a different Python than the
one ansible-core runs on. boto3 might not be importable from that Python. An
*implicit* localhost (not listed in the inventory) already uses
`ansible_playbook_python`.

## 5. Verify

1. Re-run an amazon.aws job template that previously failed with
   *"boto3/botocore required"*. It should now run.
2. Sync an `aws_ec2` inventory source that uses the new EE.
3. In the job's output and details, check that *Execution Environment* is
   `global` and that the image is the expected `ee-internal:<tag>`.
