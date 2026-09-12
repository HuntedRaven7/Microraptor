kind: stack
description: |
  Live installer environment stack. Provides systemd (with systemd-repart,
  systemd-firstboot, bootctl), cryptsetup, and the server kernel.
  NOT distroless — the installer needs tools and a shell.

  No dracut: the initrd is assembled directly from this rootfs via cpio in
  microraptor-installer.bst. This keeps the toolchain minimal and removes
  the dracut dependency chain.

  The DDI payload is embedded in the installer media (offline install).
  No network access required at install time.

depends:
  # Firmware for common hardware, pruned to the installer's target class
  # (x86_64 Chromebook/PC) so the initrd stays small enough for any UEFI
  # to load. Full linux-firmware ~1GB -> EFI stub EFI_OUT_OF_RESOURCES.
  # Ordered above the locale-carrying elements so file overlap resolves
  # in our favour.
  - installer/linux-firmware-installer.bst

  # Podman quadlet templates shipped in the installer initrd
  - installer/quadlet-chooser.bst

  # Interactive TUI for quadlet chooser and user creation
  - freedesktop-sdk.bst:components/newt.bst

  # Base runtime. runtime-gnu (ordered first) provides /bin/sh and
  # coreutils -- without a shell the microraptor-sysinstall wrapper
  # fails at EXEC (203) and the unit's FailureAction=poweroff shuts the
  # machine down ~8s after boot. runtime-minimal alone has no shell.
  - freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
  - freedesktop-sdk.bst:components/ca-certificates.bst
  - freedesktop-sdk.bst:components/tzdata.bst
  - freedesktop-sdk.bst:integration/extra-fs.bst
  - freedesktop-sdk.bst:integration/ldconfig.bst

  # systemd full (includes systemd-repart, systemd-firstboot, bootctl)
  - freedesktop-sdk.bst:components/systemd.bst
  - freedesktop-sdk.bst:components/dbus.bst
  - freedesktop-sdk.bst:components/dbus-broker.bst
  - freedesktop-sdk.bst:components/kmod.bst

  # Disk setup: LUKS partition support during install
  - freedesktop-sdk.bst:components/cryptsetup.bst
  - freedesktop-sdk.bst:components/xfsprogs.bst
  - freedesktop-sdk.bst:components/dosfstools.bst

  # repart.d configs describing the TARGET disk layout
  - installer/installer-repart.bst
