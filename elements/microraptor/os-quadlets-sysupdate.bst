kind: import
description: Install the podman-quadlets component systemd-sysupdate transfer definition.

sources:
  - kind: local
    path: files/os/sysupdate.quadlets.d

config:
  target: /usr/lib/sysupdate.quadlets.d
