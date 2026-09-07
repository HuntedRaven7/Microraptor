kind: import
description: |
  Install Tailscale configuration and enablement into the target OS image.

  Tailscale is a mesh VPN that allows secure, zero-configuration networking
  between devices. This element stages the configuration file.

sources:
  - kind: local
    path: files/os/tailscale

config:
  target: /etc/tailscale
