kind: compose
description: Compose the fsdk-it target rootfs into a single stageable artifact.

build-depends:
  - fsdk-it/os-stack.bst

config:
  exclude:
    - debug
    - devel
    - doc
  integrate: True
