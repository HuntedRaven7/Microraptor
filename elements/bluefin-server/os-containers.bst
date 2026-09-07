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
  - kind: local
    path: files/os/containers/systemd/generate-quadlets.py

config:
  install-commands:
    - |
      set -euo pipefail
      python3 generate-quadlets.py
      ls -la "%{install-root}/usr/lib/containers/systemd/"
