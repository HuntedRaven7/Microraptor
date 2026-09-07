---
name: gap-analysis-distros
description: Comparing fsdk-it to other server OSes.
metadata:
  type: reference
  status: stable
  last_updated: 2026-07-20
---
# Gap Analysis: Server OSes

## When to Use

- Comparing fsdk-it to other server OSes.

## When NOT to Use

- Design decisions within fsdk-it itself.

## Comparison

| Feature | fsdk-it | Flatcar Container Linux | Fedora CoreOS | Talos |
|---|---|---|---|---|
| Base | FSDK (BuildStream 2) | Gentoo | Fedora | Go |
| Image-based updates | Yes (A/B + sysupdate) | Yes | Yes | Yes |
| Offline installer | Yes (systemd-sysinstall) | Yes | Yes | Yes |
| Kubernetes | Optional sysext | Optional | Optional | Built-in |
| Network Manager | Yes | No (networkd) | No (networkd) | No (networkd) |
| Shell in base image | No | No | No | No |
| Container runtime | podman | Docker/MCR | Podman | containerd |

## Verification

- [ ] Comparison is up to date with current upstream features.
