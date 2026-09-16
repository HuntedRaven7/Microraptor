kind: stack
description: Stack containing all elements required to build a bootc-based microraptor rootfs.

depends:
  # Base runtime & core libraries
  - freedesktop-sdk.bst:public-stacks/runtime-minimal.bst
  - freedesktop-sdk.bst:components/ca-certificates.bst
  - freedesktop-sdk.bst:components/tzdata.bst
  - freedesktop-sdk.bst:integration/extra-fs.bst
  - freedesktop-sdk.bst:integration/ldconfig.bst

  # System Initialization, Core, and Device Management
  - freedesktop-sdk.bst:components/systemd.bst
  - freedesktop-sdk.bst:components/systemd-libs.bst
  - freedesktop-sdk.bst:components/dbus.bst
  - freedesktop-sdk.bst:components/kmod.bst
  - freedesktop-sdk.bst:components/shadow.bst
  - freedesktop-sdk.bst:components/polkit.bst
  - freedesktop-sdk.bst:components/git.bst
  - freedesktop-sdk.bst:components/vim.bst

  # Remote access for standard server administration
  - freedesktop-sdk.bst:components/openssh-systemd.bst

  # SSH enablement drop-ins and hardened access gating
  - microraptor/os-sshd-preset.bst
  - microraptor/os-sshd-config.bst
  - microraptor/os-sshd-access.bst

  # Full FSDK kernel + full firmware for the installed system
  - freedesktop-sdk.bst:components/linux.bst
  - freedesktop-sdk.bst:components/linux-firmware.bst
  - freedesktop-sdk.bst:components/wireless-regdb-bin.bst

  # Filesystem resizing support for growing root on first boot
  - freedesktop-sdk.bst:components/xfsprogs.bst

  # Systemd-native tmpfiles for core operator home and authorized_keys directory
  - microraptor/os-tmpfiles.bst

  # Passwordless sudo for wheel group
  - microraptor/os-sudo.bst
  - freedesktop-sdk.bst:components/sudo.bst

  # Sysext Compatibility Identity
  - microraptor/os-release-flatcar.bst

  # First-Boot User Provisioning
  - microraptor/os-creds-prov.bst

  # First-Boot Network Configuration (nmtui)
  - microraptor/os-first-boot.bst

  # Network Manager configuration and enablement
  - freedesktop-sdk.bst:components/networkmanager.bst
  # Wi-Fi association backend for NetworkManager (D-Bus activated)
  - freedesktop-sdk.bst:components/wpa-supplicant.bst
  - microraptor/os-network-manager.bst

  # System Management Justfile
  - microraptor/os-justfile.bst

  # Console issue banner
  - microraptor/os-issue.bst

  # bootc and its dependencies
  - microraptor/bootc.bst