kind: import
description: |
  Install console issue banner displaying dashboard URL and IP.

sources:
  - kind: local
    path: files/os/issue.d

config:
  target: /usr/lib/issue.d
