kind: compose
description: Compose the microraptor target rootfs into a single stageable artifact.

build-depends:
  - microraptor/os-stack.bst

config:
  exclude:
    - debug
    - devel
    - doc
  integrate: True
