kind: script
description: |
  Produce the microraptor OS DDI payload filesystem image.

  Output: microraptor-ddi-<ver>.raw.zst + SHA256SUMS

  The output .raw is a filesystem image consumed by installer repart config:
  files/installer/repart.d/20-root-a.conf via CopyBlocks=.

build-depends:
  - base/base-stack.bst
  - freedesktop-sdk.bst:components/xfsprogs.bst
  - freedesktop-sdk.bst:components/findutils.bst
  - freedesktop-sdk.bst:components/zstd.bst
  - filename: microraptor/os-rootfs.bst
    config:
      location: /layer

variables:
  ddi-version: "%{release-version}"

config:
  commands:
    - |
      set -euo pipefail
      OUT="%{install-root}"
      FNAME="microraptor-ddi-%{ddi-version}.raw"

      rm -rf /layer/usr/lib/debug
      find /layer -type f -name '*.debug' -delete

      # Sum actual file sizes across bind mounts (du -sb reports content bytes, not overlay blocks).
      ROOT_BYTES=$(du -sb /layer | cut -f1)
      echo "Computed root filesystem size: ${ROOT_BYTES} bytes"

      # 25% overhead and 100MB margin for XFS metadata, journal, and structures.
      TARGET_BYTES=$(( ROOT_BYTES + ROOT_BYTES / 4 + 100 * 1024 * 1024 ))

      # Align TARGET_BYTES to 4096-byte boundary (multiple of 512/4096) for sector compatibility
      TARGET_BYTES=$(( (TARGET_BYTES + 4095) / 4096 * 4096 ))

      # Pre-allocate the raw file to the exact target size.
      truncate -s "${TARGET_BYTES}" "${OUT}/${FNAME}"

      echo "Allocating XFS image of ${TARGET_BYTES} bytes"
      mkfs.xfs -f -L microraptor-root -p /layer "${OUT}/${FNAME}"

      zstd --rm -T0 -19 -q "${OUT}/${FNAME}" -o "${OUT}/${FNAME}.zst"
      ls -lh "${OUT}/${FNAME}.zst"
      which sha256sum || echo "DEBUG: sha256sum not found"
      sha256sum --version || true
      (
        cd "${OUT}"
        ls -lh "${FNAME}.zst"
        sha256sum "${FNAME}.zst" > SHA256SUMS
        echo "DEBUG: sha256sum exit=$?"
      )
