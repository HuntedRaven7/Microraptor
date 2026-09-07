---
name: k0s-sysext
description: Building the k0s sysext.
metadata:
  type: how-to
  status: stable
  last_updated: 2026-07-20
---
# k0s Sysext Build

## When to Use

- Building the k0s sysext.
- BuildStream element and publish steps for the k0s sysext.

## When NOT to Use

- Operating k0s on a running system.

## Build commands

| Command | Purpose |
|---|---|
| `just build-sysext` | Build the k0s `systemd-sysext`. |
| `just export-sysext` | Export sysext artifacts to `dist/sysext/`. |

## Verification

- [ ] `just build-sysext` completes without errors.
- [ ] `just export-sysext` produces `dist/sysext/k0s-*.raw.zst` and `SHA256SUMS`.
- [ ] `systemd-sysext status` shows the sysext as active on a running system.
