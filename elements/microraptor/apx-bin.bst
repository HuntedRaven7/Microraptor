kind: manual
description: |
  Import the pinned Archaeopteryx release tarball into the target rootfs: the
  apxd daemon + apxctl CLI, its systemd unit, and the preset that enables it
  on first boot.

  Pinned to the latest stable release for both x86_64 and aarch64. The release
  tag comes from include/apx.yml (%{apx-version}); only the SHA256 refs are
  restated here, taken from that release's SHA256SUMS asset.

# %{apx-version} — the Archaeopteryx release tag (include/apx.yml).
# %{go-arch} — Go spelling of `arch` (include/arch.yml).
(@):
  - include/apx.yml
  - include/arch.yml

build-depends:
  # Base runtime providing /bin/sh, tar, and install in the sandbox.
  - base/base-stack.bst

variables:
  # Do not try to strip the pre-built upstream binaries.
  strip-binaries: ""

sources:
  - kind: remote
    url: github:HuntedRaven7/Archaeopteryx/releases/download/%{apx-version}/archaeopteryx-%{apx-version}-linux-%{go-arch}.tar.gz
    (?):
      - arch == "x86_64":
          ref: 3ff6ed420a16d8a6f65ac1e97688097629214b8cff6ef86bfe5cad22ea333970
      - arch == "aarch64":
          ref: 7172d6651985472a4a29a8f197344e232b95788607b7571c47865ce2fe4c11cb

config:
  install-commands:
    - |
      tar -xzf archaeopteryx-%{apx-version}-linux-%{go-arch}.tar.gz
      install -D -m 0755 usr/bin/apxd "%{install-root}/usr/bin/apxd"
      install -D -m 0755 usr/bin/apxctl "%{install-root}/usr/bin/apxctl"
      install -D -m 0644 usr/lib/systemd/system/apxd.service \
        "%{install-root}/usr/lib/systemd/system/apxd.service"
      install -D -m 0644 usr/lib/systemd/system-preset/zz-enable-apxd.preset \
        "%{install-root}/usr/lib/systemd/system-preset/zz-enable-apxd.preset"