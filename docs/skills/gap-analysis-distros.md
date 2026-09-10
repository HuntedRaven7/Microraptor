---
name: gap-analysis-distros
description: Comparing microraptor to other server OSes.
metadata:
  type: reference
  status: stable
  last_updated: 2026-07-20
---
# Gap Analysis: Server OSes

## When to Use

- Comparing microraptor to other server OSes.

## When NOT to Use

- Design decisions within microraptor itself.

## Comparison

| Feature | microraptor | Flatcar Container Linux | Fedora CoreOS | Talos |
|---|---|---|---|---|
| Base | FSDK (BuildStream 2) | Gentoo | Fedora | Go |
| Image-based updates | Yes (A/B + sysupdate) | Yes | Yes | Yes |
| Offline installer | Yes (systemd-sysinstall) | Yes | Yes | Yes |
| Kubernetes | Optional sysext | Optional | Optional | Built-in |
| Network Manager | Yes | No (networkd) | No (networkd) | No (networkd) |
| Shell in base image | No | No | No | No |
| Container runtime | none (sysext optional) | Docker/MCR | Podman | containerd |

## Verification

- [ ] Comparison is up to date with current upstream features.
