kind: script
description: |
  Download and stage Ubuntu mainline kernel for Chromebook compatibility.

  Replaces the FSDK kernel with a mainstream Ubuntu kernel that has
  better Intel GPU, audio, and Chromebook-specific driver support.

build-depends:
  - freedesktop-sdk.bst:components/xz.bst
  - freedesktop-sdk.bst:components/findutils.bst
  - freedesktop-sdk.bst:components/curl.bst

config:
  commands:
    - |
      set -eux
      KVER="6.14"
      echo "Downloading Ubuntu kernel ${KVER}..."
      curl -fL "https://kernel.ubuntu.com/~kernel-ppa/mainline/v${KVER}/amd64/vmlinuz" -o /tmp/ubuntu-vmlinuz
      curl -fL "https://kernel.ubuntu.com/~kernel-ppa/mainline/v${KVER}/amd64/modules.tar.xz" -o /tmp/ubuntu-modules.tar.xz
      mkdir -p /usr/lib/modules
      tar -xf /tmp/ubuntu-modules.tar.xz -C /usr/lib/modules/
      ACTUAL_KVER="$(ls /usr/lib/modules | head -1)"
      cp /tmp/ubuntu-vmlinuz "/usr/lib/modules/${ACTUAL_KVER}/vmlinuz"
      echo "Staged Ubuntu kernel ${ACTUAL_KVER}"
      ls -lh /usr/lib/modules/
