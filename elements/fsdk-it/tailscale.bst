kind: manual
description: |
  Install the Tailscale client binary into the target OS image.

  Tailscale is not available as an FSDK component, so we download the
  pre-built static binary from the official GitHub releases at build time.

build-depends:
  - base/base-stack.bst

sources:
  - kind: local
    path: files/os/tailscale

config:
  install-commands:
    - |
      set -euo pipefail
      TAILSCALE_VERSION="1.102.3"
      ARCH="amd64"
      URL="https://github.com/tailscale/tailscale/releases/download/v${TAILSCALE_VERSION}/tailscale_${TAILSCALE_VERSION}_${ARCH}.tgz"
      mkdir -p "%{install-root}/usr/bin"
      mkdir -p "%{install-root}/etc/tailscale"
      export TAILSCALE_URL="${URL}"
      python3 download-tailscale.py
      install -m 0755 /tmp/tailscale "%{install-root}/usr/bin/tailscale"
      install -m 0755 /tmp/tailscaled "%{install-root}/usr/bin/tailscaled"
