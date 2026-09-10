kind: manual
description: |
  Minimal custom Linux kernel for Chromebook hardware enablement.

  Built from Linux 6.14 source with a trimmed config containing only:
  - Intel i915 GPU + audio
  - eMMC/SD (sdhci_acpi, cqhci)
  - SATA/NVMe, USB storage
  - XFS/EROFS/OverlayFS
  - VirtIO, Intel networking
  - systemd-required cgroups/namespaces

  Replaces the stock FSDK kernel which lacks Chromebook driver support.

sources:
  - kind: tar
    url: https://cdn.kernel.org/pub/linux/kernel/v6.x/linux-6.14.tar.xz
    ref: 6.14
  - kind: local
    path: files/installer/linux-chromebook.config

build-depends:
  - base/base-stack.bst
  - freedesktop-sdk.bst:components/bc.bst
  - freedesktop-sdk.bst:components/flex.bst
  - freedesktop-sdk.bst:components/bison.bst
  - freedesktop-sdk.bst:components/pahole.bst
  - freedesktop-sdk.bst:components/kmod.bst
  - freedesktop-sdk.bst:components/openssl.bst

variables:
  strip-binaries: ''

config:
  install-commands:
    - |
      set -eux
      cd /buildstream-install
      tar -xf linux-6.14.tar.xz
      cd linux-6.14

      cp ../linux-chromebook.config .config
      make olddefconfig

      make -j"$(nproc)" all
      make -j"$(nproc)" modules

      mkdir -p /buildstream-install/boot /buildstream-install/usr/lib/modules
      cp arch/x86/boot/bzImage /buildstream-install/boot/vmlinuz
      make modules_install INSTALL_MOD_PATH=/buildstream-install

      echo "Installed custom kernel $(make kernelrelease)"
