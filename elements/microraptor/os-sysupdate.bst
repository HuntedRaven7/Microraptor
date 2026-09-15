kind: import
description: Install systemd-sysupdate transfer definitions into target OS image.

sources:
  - kind: local
    path: files/os/sysupdate.d
  - kind: local
    path: files/os/sysupdate.k0s.d

config:
  target: /usr/lib/sysupdate.d
