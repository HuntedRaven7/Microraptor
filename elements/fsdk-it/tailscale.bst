kind: manual
description: |
  Install the Tailscale client binary into the target OS image.

  Tailscale is not available as an FSDK component, so we fetch the
  pre-built static binary from the official package server.

build-depends:
  - base/base-stack.bst

sources:
  - kind: tar
    url: https://pkgs.tailscale.com/stable/tailscale_1.102.3_amd64.tgz
    ref: 36ddd9b51be57ffc2990cf76323cfa13643bfbb1b8a969f6183fa164741cdef5

config:
  install-commands:
    - |
      set -euo pipefail
      mkdir -p "%{install-root}/usr/bin"
      mkdir -p "%{install-root}/etc/tailscale"
      install -m 0755 tailscale_1.102.3_amd64/tailscale "%{install-root}/usr/bin/tailscale"
      install -m 0755 tailscale_1.102.3_amd64/tailscaled "%{install-root}/usr/bin/tailscaled"
