kind: script
description: |
  Download and stage Ubuntu mainline kernel for Chromebook compatibility.

  Replaces the FSDK kernel with a mainstream Ubuntu kernel that has
  better Intel GPU, audio, and Chromebook-specific driver support.

sources:
  - kind: url
    url: https://kernel.ubuntu.com/~kernel-ppa/mainline/v6.14/amd64/vmlinuz
    filename: ubuntu-vmlinuz
  - kind: url
    url: https://kernel.ubuntu.com/~kernel-ppa/mainline/v6.14/amd64/modules.tar.xz
    filename: ubuntu-modules.tar.xz

build-depends:
  - freedesktop-sdk.bst:components/xz.bst
  - freedesktop-sdk.bst:components/findutils.bst

config:
  commands:
    - |
      set -eux
      mkdir -p /usr/lib/modules
      tar -xf ubuntu-modules.tar.xz -C /usr/lib/modules/
      KVER=$(ls /usr/lib/modules | head -1)
      cp ubuntu-vmlinuz "/usr/lib/modules/${KVER}/vmlinuz"
      echo "Staged Ubuntu kernel ${KVER}"
      ls -lh /usr/lib/modules/
