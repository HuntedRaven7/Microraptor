kind: import
description: |
  Install the first-boot network configuration service that launches nmtui
  on the initial boot, then marks first-boot as complete.

sources:
  - kind: local
    path: files/os/systemd/system

config:
  target: /usr/lib/systemd/system