kind: stack
description: Stack containing all elements required to build a pure DDI fsdk-it rootfs.

depends:
  # Base runtime & core libraries
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
  - freedesktop-sdk.bst:components/ca-certificates.bst
  - freedesktop-sdk.bst:components/tzdata.bst
  - freedesktop-sdk.bst:integration/extra-fs.bst
  - freedesktop-sdk.bst:integration/ldconfig.bst

  # System Initialization, Core, and Device Management
  - freedesktop-sdk.bst:components/systemd.bst
  - freedesktop-sdk.bst:components/kmod.bst
  - freedesktop-sdk.bst:components/shadow.bst

  # Remote access for standard server administration
  - freedesktop-sdk.bst:components/openssh-systemd.bst

  # SSH enablement drop-ins
  - fsdk-it/os-sshd-preset.bst
  - fsdk-it/os-sshd-config.bst

  # Stock FSDK Kernel & Server-Chiseled Firmware
  - freedesktop-sdk.bst:components/linux.bst
  - fsdk-it/linux-firmware-split.bst

  # Filesystem resizing support for growing root/var on first boot
  - freedesktop-sdk.bst:components/xfsprogs.bst

  # Sysext Compatibility Identity
  - fsdk-it/os-release-flatcar.bst

  # A/B System Update Configurations
  - fsdk-it/os-sysupdate.bst

  # Public keyring for verifying SHA256SUMS manifests from GitHub Releases
  - fsdk-it/os-sysupdate-keys.bst

  # gpg binary required by systemd-sysupdate to verify SHA256SUMS.gpg
  - freedesktop-sdk.bst:components/gnupg.bst

  # First-Boot Credentials Provisioning
  - fsdk-it/os-creds-prov.bst

  # Reboot Coordination for Kured
  - fsdk-it/os-kured-hook.bst

  # Container Runtime support
  - freedesktop-sdk.bst:components/podman.bst

  # Network Manager configuration and enablement
  - freedesktop-sdk.bst:components/networkmanager.bst
  - fsdk-it/os-network-manager.bst

  # System Management Justfile
  - fsdk-it/os-justfile.bst

  # Console issue banner
  - fsdk-it/os-issue.bst

  # Podman Quadlets for common services
  - fsdk-it/os-containers.bst
