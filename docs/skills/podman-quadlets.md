---
name: podman-quadlets
description: Working with Podman quadlets on microraptor.
metadata:
  type: how-to
  status: stable
  last_updated: 2026-07-20
---
# Podman Quadlets

## When to Use

- Working with Podman quadlets on microraptor.
- Podman quadlet deployment and management.

## When NOT to Use

- Non-systemd container workloads.

## Overview

Podman is included in the base OS stack for container workloads. Quadlets are systemd-native container unit files that Podman generates from `.container`, `.volume`, and `.network` files placed in `/etc/containers/systemd/` or `/usr/lib/containers/systemd/`.

## Usage

```bash
# Place a quadlet file
sudo cp myapp.container /etc/containers/systemd/

# Generate and enable the systemd unit
sudo systemctl daemon-reload
sudo systemctl enable --now myapp.service

# Check status
sudo systemctl status myapp.service
sudo podman ps
```

## Quadlet file locations

- `/etc/containers/systemd/` — administrator-provided quadlets
- `/usr/lib/containers/systemd/` — OS-provided quadlets

## Version management

Quadlet image versions are pinned in [`include/quadlets.yml`](../include/quadlets.yml) and generated into the final `.container` files by [`.github/scripts/update-quadlets.py`](../../.github/scripts/update-quadlets.py). The GitHub Actions workflow [`.github/workflows/quadlets.yml`](../../.github/workflows/quadlets.yml) can update versions and create a pull request with the changes.

To update versions locally:

```bash
python3 .github/scripts/update-quadlets.py --pihole 2024.07 --glance 0.8
```

To update via GitHub Actions, trigger the `Manage Quadlet Versions` workflow with the desired image tags.

## Verification

- [ ] `systemctl status <service>` shows the container as active.
- [ ] `podman ps` shows the running container.
- [ ] `podman logs <container>` shows expected output.
- [ ] Image versions in `include/quadlets.yml` are pinned and not `:latest`.
