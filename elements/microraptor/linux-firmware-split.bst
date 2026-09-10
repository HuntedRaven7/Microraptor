kind: compose
description: Chisel linux-firmware down to essential blobs for server and Chromebook-class hardware.

build-depends:
  - freedesktop-sdk.bst:components/linux-firmware.bst

config:
  integrate: False

  exclude:
    - debug
    - devel
    - doc
    - locale

  include:
    # CPU Microcodes
    - /usr/lib/firmware/intel-ucode/**
    - /usr/lib/firmware/amd-ucode/**

    # Intel GPU / display
    - /usr/lib/firmware/i915/**

    # Intel audio
    - /usr/lib/firmware/intel/audio/**

    # Intel networking
    - /usr/lib/firmware/intel/igc/**

    # Intel chipset / management engine
    - /usr/lib/firmware/intel/me/**

    # VirtIO / KubeVirt guest hardware support
    - /usr/lib/firmware/virtio/**

    # Standard Ethernet & Storage controllers
    - /usr/lib/firmware/intel/e1000/**
    - /usr/lib/firmware/intel/e810/**
    - /usr/lib/firmware/realtek/**

    # Regulatory database
    - /usr/lib/firmware/regulatory.db*

    # Intel WiFi
    - /usr/lib/firmware/iwlwifi/**

    # Atheros WiFi
    - /usr/lib/firmware/ath9k/**
    - /usr/lib/firmware/ath10k/**
    - /usr/lib/firmware/ath11k/**

    # MediaTek WiFi
    - /usr/lib/firmware/mt7921/**
    - /usr/lib/firmware/mt7922/**
    - /usr/lib/firmware/mt7925/**

    # Realtek WiFi
    - /usr/lib/firmware/rtw88/**
