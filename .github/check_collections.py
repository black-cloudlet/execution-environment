"""Fail if an installed collection does not support this image's ansible-core.

Runs inside the EE during the smoke test. Reads each collection's
meta/runtime.yml `requires_ansible` and lists every mismatch at once.
"""
import glob
import sys

import yaml
from ansible.release import __version__ as core_version
from packaging.specifiers import SpecifierSet
from packaging.version import Version

ROOT = "/usr/share/ansible/collections/ansible_collections"
core = Version(core_version)
bad = []

for runtime in sorted(glob.glob(f"{ROOT}/*/*/meta/runtime.yml")):
    name = ".".join(runtime.split("/")[-4:-2])
    with open(runtime) as fh:
        requires = (yaml.safe_load(fh) or {}).get("requires_ansible")
    if requires and core not in SpecifierSet(requires.replace(" ", ""), prereleases=True):
        bad.append(f"  {name}: requires ansible-core {requires}")

print(f"ansible-core {core_version}")
if bad:
    print("Collections that do not support this ansible-core:")
    print("\n".join(bad))
    sys.exit(1)
print("all collections support this ansible-core")
