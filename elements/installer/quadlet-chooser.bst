kind: script
description: |
  Copies podman quadlet templates into the installer initrd staging area
  so the post-install chooser can present them to the user.

build-depends:
  - base/base-stack.bst

config:
  commands:
    - |
      set -eux
      DST="%{install-root}/usr/share/microraptor/quadlets"
      mkdir -p "${DST}"
      cp -a ./*.quadlet "${DST}/" 2>/dev/null || true
