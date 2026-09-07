kind: import
description: |
  Install the public GPG keyring used by systemd-sysupdate to verify
  SHA256SUMS.gpg from GitHub Releases.

  The keyring is shipped in this repository and installed into
  /usr/lib/sysupdate.extra.d/ so systemd-sysupdate can find it at
  update time.

  TODO: replace the placeholder key with the actual release-signing
  public key before first production release.

sources:
  - kind: local
    path: files/os/sysupdate-keys

config:
  target: /usr/lib/sysupdate.extra.d
