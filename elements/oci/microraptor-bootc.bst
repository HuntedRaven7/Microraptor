kind: script
description: |
  Produce the microraptor bootc OCI image.

  Output: OCI image layout with containers.bootc=1 label, pushed to registry.

build-depends:
  - gnome-build-meta.bst:freedesktop-sdk.bst:components/fakecap.bst
  - gnome-build-meta.bst:freedesktop-sdk.bst:components/oci-builder.bst
  - freedesktop-sdk.bst:components/glib.bst
  - gnome-build-meta.bst:freedesktop-sdk.bst:vm/prepare-image.bst
  - filename: oci/layers/microraptor.bst
    config:
      location: /layer
  - filename: oci/layers/microraptor-init-scripts.bst
    config:
      location: /initial_scripts

environment:
  LD_PRELOAD: /usr/libexec/fakecap/fakecap.so
  FAKECAP_DB: /fakecap

variables:
  sysroot-seed: b57666f6-0fe5-4310-adff-f256936d164d
  image-repo: microraptor
  ownership-variant: default

config:
  commands:
    - mkdir /fakecap
    - |
      prepare-image.sh \
         --sysroot /layer \
         --initscripts /initial_scripts \
         --seed "%{sysroot-seed}" \
         --noroot --noboot >/dev/null

    - |
      systemd-sysusers --root /layer

    - |
      glib-compile-schemas /layer/usr/share/glib-2.0/schemas

    - |
      if [ -d /layer/usr/etc ]; then
        mkdir -p /layer/etc
        cp -a /layer/usr/etc/. /layer/etc/
        rm -rf /layer/usr/etc
      fi

    - |
      dconf update /layer/etc/dconf/db || true

    - |
      ldconfig -r /layer -f /layer/etc/ld.so.conf

    - |
      mkdir -p /layer/usr/lib/bootc/install
      printf '[install]\nbootloader = "systemd"\n\n[install.filesystem.root]\ntype = "xfs"\n' > /layer/usr/lib/bootc/install/00-defaults.toml

    - |
      mkdir -p /layer/usr/lib/bootc/kargs.d
      printf 'kargs = [\n    "console=ttyS0,115200",\n    "console=tty0",\n    "systemd.firstboot=no",\n]\n' > /layer/usr/lib/bootc/kargs.d/10-console.toml

    - |
      cd "%{install-root}"
      # Map BuildStream arch to Go arch for OCI labels
      case "%{arch}" in
        x86_64) GO_ARCH="amd64" ;;
        aarch64) GO_ARCH="arm64" ;;
        *) echo "Unknown arch: %{arch}" >&2; exit 1 ;;
      esac
      build-oci <<EOF
      mode: oci
      gzip: disabled
      images:
      - os: linux
        architecture: "$GO_ARCH"
        layer: /layer
        comment: "Import Microraptor layer"
        config:
          Labels:
            'com.github.containers.toolbox': 'true'
            'org.opencontainers.image.title': 'Microraptor'
            'org.opencontainers.image.description': 'An FSDK-based, image-based Linux server OS'
            'org.opencontainers.image.vendor': 'Microraptor Project'
            'org.opencontainers.image.licenses': 'Apache-2.0'
            'org.opencontainers.image.url': 'https://github.com/HuntedRaven7/Microraptor'
            'org.opencontainers.image.source': 'https://github.com/HuntedRaven7/Microraptor'
            'containers.bootc': '1'
        index-annotations:
          'org.opencontainers.image.ref.name': 'ghcr.io/${{ github.repository_owner }}/%{image-repo}:latest'
      EOF