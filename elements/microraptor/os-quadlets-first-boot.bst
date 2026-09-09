kind: import
description: Install the first-boot podman-quadlets sysext activation units.

sources:
  - kind: local
    path: files/os/systemd/system

config:
  target: /usr/lib/systemd/system
