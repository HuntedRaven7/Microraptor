kind: import
description: |
  Install a systemd preset that enables sshd.service on first boot.

sources:
  - kind: local
    path: files/os/systemd/system-preset

config:
  target: /usr/lib/systemd/system-preset
