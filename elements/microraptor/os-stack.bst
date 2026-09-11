kind: stack
description: Stack containing all elements required to build a pure DDI microraptor rootfs.

depends:
  # Base runtime & core libraries
  - freedesktop-sdk.bst:public-stacks/runtime-gnu.bst
  - freedesktop-sdk.bst:components/ca-certificates.bst
  - freedesktop-sdk.bst:components/tzdata.bst
  - freedesktop-sdk.bst:integration/extra-fs.bst
  - freedesktop-sdk.bst:integration/ldconfig.bst

  # System Initialization, Core, and Device Management
  - freedesktop-sdk.bst:components/systemd.bst
  - freedesktop-sdk.bst:components/dbus.bst
  - freedesktop-sdk.bst:components/dbus-broker.bst
  - freedesktop-sdk.bst:components/kmod.bst
  - freedesktop-sdk.bst:components/shadow.bst
  - freedesktop-sdk.bst:components/polkit.bst
  - freedesktop-sdk.bst:components/nftables.bst

  # Remote access for standard server administration
  - freedesktop-sdk.bst:components/openssh-systemd.bst

  # SSH enablement drop-ins
  - microraptor/os-sshd-preset.bst
  - microraptor/os-sshd-config.bst

  # Custom minimal Chromebook kernel (i915, sdhci_acpi, cqhci, Intel audio)
  - installer/linux-chromebook.bst
  - microraptor/linux-firmware-split.bst

  # Filesystem resizing support for growing root/var on first boot
  - freedesktop-sdk.bst:components/xfsprogs.bst

  # Sysext Compatibility Identity
  - microraptor/os-release-flatcar.bst

  # A/B System Update Configurations
  - microraptor/os-sysupdate.bst

  # k0s component system update configuration
  - microraptor/os-k0s-sysupdate.bst

  # Activate the optional k0s sysext after installation
  - microraptor/os-k0s-first-boot.bst

  # Public keyring for verifying SHA256SUMS manifests from GitHub Releases
  - microraptor/os-sysupdate-keys.bst

  # gpg binary required by systemd-sysupdate to verify SHA256SUMS.gpg
  - freedesktop-sdk.bst:components/gnupg.bst

  # First-Boot Credentials Provisioning
  - microraptor/os-creds-prov.bst

  # Reboot Coordination for Kured
  - microraptor/os-kured-hook.bst

  # Network Manager configuration and enablement
  - freedesktop-sdk.bst:components/networkmanager.bst
  - microraptor/os-network-manager.bst

  # Archaeopteryx control plane daemon (apx API + node management)
  - microraptor/apx-bin.bst

  # System Management Justfile
  - microraptor/os-justfile.bst

  # Console issue banner
  - microraptor/os-issue.bst
