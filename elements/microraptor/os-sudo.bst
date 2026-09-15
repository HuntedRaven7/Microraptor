kind: import
description: Install passwordless sudo configuration for the wheel group.

sources:
  - kind: local
    path: files/os/sudoers.d

config:
  target: /etc/sudoers.d