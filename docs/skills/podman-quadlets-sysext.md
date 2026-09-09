---
name: podman-quadlets-sysext
description: Building the podman-quadlets sysext.
metadata:
  type: how-to
  status: stable
  last_updated: 2026-09-09
---
# Podman Quadlets Sysext Build

## When to Use

- Building the optional podman-quadlets `systemd-sysext`.
- BuildStream element and publish steps for the podman-quadlets sysext.

## When NOT to Use

- Configuring quadlets baked into the base DDI (use `os-containers.bst` instead).

## Build commands

| Command | Purpose |
|---|---|
| `just build-podman-quadlets-sysext` | Build the podman-quadlets `systemd-sysext`. |
| `just export-podman-quadlets-sysext` | Export sysext artifacts to `dist/sysext/`. |

## How it works

The sysext is an independently updatable EROFS layer that overlays `/usr/` at runtime.
It ships example quadlet files under `/usr/share/quadlets/examples/` and a
`quadlets-pull.service` unit that copies enabled quadlets into
`/var/lib/containers/systemd/` and pulls their images.

At first boot (or after a sysupdate), the `quadlets-first-boot.service` unit:

1. Copies the downloaded sysext raw image to `/run/extensions/podman-quadlets.raw`.
2. Runs `systemd-sysext merge` to overlay the sysext into `/usr/`.
3. Runs `systemd-tmpfiles --create` to seed `/var/lib/containers/systemd/`.
4. Runs `systemctl daemon-reload`.
5. Enables and starts `quadlets-pull.service` to activate the quadlets.

If the installer pre-seeds the sysext raw image at `/var/lib/podman-quadlets/quadlets.raw`,
the network fetch step (`quadlets-first-boot-fetch.service`) is skipped.

## Verification

- [ ] `just build-podman-quadlets-sysext` completes without errors.
- [ ] `just export-podman-quadlets-sysext` produces `dist/sysext/podman-quadlets-*.raw.zst` and `SHA256SUMS`.
- [ ] `systemd-sysext status` shows the sysext as active on a running system.
- [ ] `systemctl status quadlets-pull.service` shows the pull unit as active after boot.
