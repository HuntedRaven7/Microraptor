kind: manual
description: |
  Install Network Manager configuration and enablement into the target OS image.

  Network Manager is added to the base OS stack for dynamic network
  configuration management. This element stages configuration files
  and ensures the service is enabled on first boot.

sources:
  - kind: local
    path: files/os/NetworkManager

config:
  target: /etc/NetworkManager
