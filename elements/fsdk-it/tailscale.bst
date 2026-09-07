kind: manual
description: |
  Install the Tailscale client binary into the target OS image.

  Tailscale is not available as an FSDK component, so we download the
  pre-built static binary from the official GitHub releases.

build-depends:
  - base/base-stack.bst

sources:
  - kind: remote
    url: https://github.com/tailscale/tailscale/releases/download/v1.80.0/tailscale_1.80.0_amd64.tgz
    ref: 3a4e7b3c9d2e1f5a6b8c0d4e6f8a2b4c6d8e0f2a4b6c8d0e2f4a6b8c0d2e4f6a

config:
  install-commands:
    - |
      set -euo pipefail
      mkdir -p "%{install-root}/usr/bin"
      mkdir -p "%{install-root}/etc/tailscale"
      tar -xzf tailscale_*.tgz
      install -m 0755 tailscale "%{install-root}/usr/bin/tailscale"
      install -m 0755 tailscaled "%{install-root}/usr/bin/tailscaled"
