kind: compose
description: Chisel linux-firmware down to server-essential blobs only for extreme efficiency.

build-depends:
  - freedesktop-sdk.bst:components/linux-firmware.bst

config:
  integrate: False

  # Exclude debug symbols, development files, and locales from composed output
  exclude:
    - debug
    - devel
    - doc
    - locale

  # Only include CPU microcode, virtual, net, and Intel/AMD firmware needed for servers
  include:
    # CPU Microcodes (intel & amd)
    - /usr/lib/firmware/intel-ucode/**
    - /usr/lib/firmware/amd-ucode/**

    # Intel GPU / display
    - /usr/lib/firmware/i915/**

    # Intel audio
    - /usr/lib/firmware/intel/audio/**

    # Intel networking
    - /usr/lib/firmware/intel/igc/**

    # VirtIO / KubeVirt guest hardware support
    - /usr/lib/firmware/virtio/**

    # Standard Ethernet & Storage controllers
    - /usr/lib/firmware/intel/e1000/**
    - /usr/lib/firmware/intel/e810/**
    - /usr/lib/firmware/realtek/**

    # Regulatory database
    - /usr/lib/firmware/regulatory.db*
