kind: manual
description: |
  Produce a systemd-sysext extension image for podman quadlets.

  Output: podman-quadlets-<version>.raw, podman-quadlets-<version>.raw.zst,
  and SHA256SUMS.  Contains the existing quadlet files under
  files/quadlets/sysext/ staged as an examples pool, plus the extension
  release metadata and a tmpfiles.d seeding configuration.

(@):
  - include/arch.yml
  - include/quadlets.yml

build-depends:
  - base/base-stack.bst
  - freedesktop-sdk.bst:components/erofs-utils.bst
  - freedesktop-sdk.bst:components/xz.bst
  - freedesktop-sdk.bst:components/zstd.bst

sources:
  - kind: local
    path: files/quadlets/sysext
    directory: sysext-src

variables:
  strip-binaries: ""

config:
  install-commands:
    - |
      set -euo pipefail
      OUT="%{install-root}"
      FNAME="podman-quadlets-%{quadlets-version}.raw"

      mkdir -p sysext/usr/lib/extension-release.d
      mkdir -p sysext/usr/lib/tmpfiles.d
      mkdir -p sysext/usr/share/quadlets/examples
      mkdir -p "${OUT}"

      # Stage extension release metadata
      cp -a sysext-src/extension-release.quadlets sysext/usr/lib/extension-release.d/
      echo "VERSION_ID=%{quadlets-version}" >> sysext/usr/lib/extension-release.d/extension-release.quadlets
      echo "ARCHITECTURE=%{systemd-arch}" >> sysext/usr/lib/extension-release.d/extension-release.quadlets

      # Stage tmpfiles seeding configuration
      cp -a sysext-src/quadlets-manifests.conf sysext/usr/lib/tmpfiles.d/

      # Stage example quadlets
      cp -a sysext-src/*.container sysext/usr/share/quadlets/examples/

      # Build EROFS image
      mkfs.erofs -d0 "${OUT}/${FNAME}" sysext

      # Compress release asset
      zstd -T0 -19 -q "${OUT}/${FNAME}" -o "${OUT}/${FNAME}.zst"

      (
        cd "${OUT}"
        sha256sum --binary "${FNAME}.zst" > SHA256SUMS
      )
