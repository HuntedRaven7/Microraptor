kind: script
description: |
  linux-firmware pruned to the installer's target class (x86_64
  Chromebook/PC), for embedding in the boot-time installer initrd.

  The full FSDK linux-firmware tree is ~1GB, most of it for server/ARM
  silicon (nvidia, qcom, mellanox, mrvl, mediatek, netronome, ...).
  Embedding the whole tree made the installer UKI's embedded initrd so
  large that the EFI stub failed to load it (EFI_OUT_OF_RESOURCES,
  0x8000000000000009) and firmware fell through to the next boot option
  on UEFI-only machines.

  Wireless firmware is kept even though the installer only configures
  wired DHCP: the same initrd supports later headless rescue sessions
  where Wi-Fi may be the only link.

  NOTE: kind:compose include-path filtering does not restrict the tree in
  the installed BuildStream (2.7.0) -- both linux-firmware-split.bst and
  an earlier compose variant of this element produced the FULL
  /usr/lib/firmware tree. A script element that copies a keep-list is the
  only mechanism that actually limits content. Re-evaluate if upstream
  bst starts filtering compose includes.

build-depends:
  # Toolchain for the copy commands (sh, cp, mkdir): base-stack's
  # runtime-gnu/runtime-minimal provide a shell and coreutils.
  - base/base-stack.bst
  # Source tree to filter
  - freedesktop-sdk.bst:components/linux-firmware.bst

config:
  commands:
    - |
      set -eux
      SRC=/usr/lib/firmware
      DST="%{install-root}/usr/lib/firmware"
      mkdir -p "${DST}"

      # Graphics (Intel, Intel Xe, AMD) -- covers the Chromebook + PC class
      KEEP="i915 xe intel amdgpu radeon"

      # Wireless / Bluetooth commonly present in Chromebooks and laptops
      KEEP="${KEEP} ath10k ath11k ath12k ath6k brcm qca cypress"
      KEEP="${KEEP} rtl_bt rtlwifi rtw88 rtw89 mwlwifi mwl8k"

      # Audio + common wired NICs
      KEEP="${KEEP} cirrus rtl_nic e100"

      for d in ${KEEP}; do
        if [ -d "${SRC}/${d}" ]; then
          cp -a "${SRC}/${d}" "${DST}/"
        else
          echo "warning: ${SRC}/${d} not present in source tree" >&2
        fi
      done