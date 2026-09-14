kind: import
description: |
  Install the first-boot credential provisioning service that seeds the root
  password as a systemd credential (TPM2-sealed when available), plus the
  systemd-sysusers drop-in that imports that credential when creating the
  root account.

sources:
  - kind: local
    path: files/os/cred-provision

config:
  target: /usr/lib/systemd