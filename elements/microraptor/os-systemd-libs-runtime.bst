kind: script
description: Extract systemd versioned shared libraries from systemd-base for DDI runtime.

build-depends:
  - base/base-stack.bst
  - freedesktop-sdk.bst:components/findutils.bst
  - freedesktop-sdk.bst:components/_private/systemd-base.bst

config:
  commands:
    - |
      set -euo pipefail
      echo "=== Debug: systemd-base staged files ==="
      find /usr -name 'libsystemd*' -o -name 'libudev*' 2>/dev/null | head -20
      echo "=== End debug ==="
      # The systemd-base component has the full build with versioned libraries
      # Copy them to the runtime location
      mkdir -p /layer/usr/lib
      # Find and copy versioned systemd libraries
      for lib in /usr/lib/libsystemd-*.so* /usr/lib/libudev-*.so*; do
        if [ -f "${lib}" ]; then
          cp -av "${lib}" /layer/usr/lib/
        fi
      done