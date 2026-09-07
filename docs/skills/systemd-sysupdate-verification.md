---
name: systemd-sysupdate-verification
description: Image-based A/B updates and signed manifests.
metadata:
  type: reference
  status: stable
  last_updated: 2026-07-20
---
# systemd-sysupdate Verification

## When to Use

- Image-based A/B updates and signed manifests.
- Release signing, `systemd-sysupdate`, and trust model.

## When NOT to Use

- Package-level updates.

## Trust model

1. Every GitHub Release contains a single combined `SHA256SUMS` manifest and its detached, ASCII-armored GPG signature `SHA256SUMS.gpg`.
2. Running systems verify the same manifest automatically via `systemd-sysupdate`.
3. The public keyring is shipped in `files/os/sysupdate-keys/import-pubring.gpg`.

## Verifying a release

```sh
# Download SHA256SUMS and SHA256SUMS.gpg from the release, then:
gpg --no-default-keyring \
    --keyring files/os/sysupdate-keys/import-pubring.gpg \
    --verify SHA256SUMS.gpg SHA256SUMS
sha256sum --check SHA256SUMS
```

## Verification

- [ ] Release artifacts include `SHA256SUMS` and `SHA256SUMS.gpg`.
- [ ] `gpg --verify` passes on downloaded artifacts.
- [ ] `systemd-sysupdate` can discover and apply updates.
