kind: import
description: |
  Install systemd service drop-ins and helper units for hardened core SSH access.

  - bluefin-core-access.service gates sshd on core authorized_keys readiness.
  - sshd.service.d/10-bluefin-access.conf requires host key and access units.

sources:
  - kind: local
    path: files/os/systemd/system

config:
  target: /usr/lib/systemd/system