---
name: systemd-sysext-extensions
description: Optional layers via systemd-sysext / systemd-confext.
metadata:
  type: reference
  status: stable
  last_updated: 2026-07-20
---
# systemd-sysext Extensions

## When to Use

- Optional layers via `systemd-sysext` / `systemd-confext`.
- Extension identity, loading, and Flatcar compatibility.

## When NOT to Use

- Base image modifications.

## Overview

`systemd-sysext` allows overlaying `/usr/` with EROFS images at runtime without modifying the base DDI. This keeps the base image small and allows optional components to be delivered and updated independently.

## Flatcar compatibility

The OS reports `ID=flatcar` in `os-release` to enable Flatcar Bakery matching and sysext compatibility.

## Verification

- [ ] `systemd-sysext status` shows expected extensions.
- [ ] `systemd-sysext refresh` updates extensions without rebooting.
