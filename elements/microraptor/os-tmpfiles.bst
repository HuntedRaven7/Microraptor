kind: import
description: Install tmpfiles.d entries for core operator home and SSH key directory.

sources:
  - kind: local
    path: files/os/tmpfiles.d

config:
  target: /usr/lib/tmpfiles.d