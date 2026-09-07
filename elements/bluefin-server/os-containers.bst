kind: manual
description: |
  Generate and install pre-configured Podman quadlet files into the target OS image.

  Quadlet versions are pinned in include/quadlets.yml. This element reads that
  file, substitutes the versions into the templates, and installs the resulting
  quadlet files into /usr/lib/containers/systemd/ so systemd can generate and
  manage the container services automatically.

build-depends:
  - base/base-stack.bst

sources:
  - kind: local
    path: include/quadlets.yml
  - kind: local
    path: files/os/containers/systemd/templates
    directory: templates

config:
  install-commands:
    - |
      set -euo pipefail
      python3 -c '
import re
import sys
from pathlib import Path

ROOT = Path(".")
quadlets_yml = ROOT / "quadlets.yml"
templates_dir = ROOT / "templates"
target_dir = Path("%{install-root}") / "usr/lib/containers/systemd"
target_dir.mkdir(parents=True, exist_ok=True)

# Parse quadlets.yml for image versions
versions = {}
text = quadlets_yml.read_text()
for name, image in re.findall(r"^\s*([a-z_]+)-image:\s*[\"]([^\"]+)[\"]", text, re.MULTILINE):
    versions[name.upper() + "_IMAGE"] = image

# Substitute templates
for tmpl in templates_dir.glob("*.container"):
    content = tmpl.read_text()
    for var, value in versions.items():
        content = content.replace("{{" + var + "}}", value)
    out = target_dir / tmpl.name
    out.write_text(content)
    print(f"Generated {out}")
'
    ls -la "%{install-root}/usr/lib/containers/systemd/"
