---
name: factory-integration
description: Understand microraptor's role as the core OS for an image-based CI/OS factory and how optional workloads run on it.
metadata:
  type: reference
  status: stable
  last_updated: 2026-09-15
---
# Factory Integration

microraptor is not a generic server distribution; it is the core operating system for an image-based CI/OS factory.

The factory pattern is broader than a single host: a downstream CI lab or OS factory uses microraptor as the base OS for automated provisioning, image-based updates, and optional runtime workloads. That environment shapes the design of this repository.

## Workloads are containers

The workloads the factory tests and ships live in other repositories or image pipelines.

> microraptor is the factory floor; optional workloads and variant images run on that floor.

## Why this matters for server design

| Factory need | Server decision |
|---|---|
| Fully automated, unattended installs | Offline bootc installer (`bootc install to-disk`) |
| Atomic, rollback-capable updates | Image-based in-place upgrades via `bootc upgrade` from GHCR |
| Minimal attack surface / no shell in OS | Distroless bootc image; optional tools as sysexts |
| Kubernetes control plane on every node | k0s delivered as `systemd-sysext` |
| Signed, verifiable release artifacts | GHCR image digests + optional cosign |

## SSH and Remote Diagnostics

> `sshd` is present in the OS image for on-demand diagnostics and bring-up troubleshooting, but is disabled by default via `disable sshd.service` in systemd presets. Operators can start it on-demand with `systemctl start sshd` or enable it when remote access is required. Root login is permitted with password and pubkey.

SSH access is key-only for the `core` operator account (`PermitRootLogin no`, `PasswordAuthentication no`). Root login and password authentication are completely disabled. `sshd` is enabled at boot and gated by `bluefin-core-access.service`, starting only after `core` authorization keys are provisioned via `tmpfiles.extra`. Operators connect as `core` and elevate with passwordless sudo:

```sh
ssh core@server.example
sudo -i
```

## Firmware and uncommon NICs

The base image includes full `linux-firmware` and `wireless-regdb` for common adapters, plus `wpa-supplicant` as the NetworkManager Wi-Fi backend. Intel `iwlwifi` (AX/BE) and MediaTek `mt7921e`/`mt7925e` drivers are preloaded in the target initramfs. Uncommon or very new NICs may still require additional proprietary firmware blobs that are not shipped in the base image. If a network interface does not appear in `nmtui`:

1. Check `dmesg | grep -i firmware` for missing firmware requests.
2. Check `lspci -k` or `lsusb` to identify the chipset.
3. Provide the PCI/USB ID to the microraptor maintainers so the firmware can be added to the build.

## When to Use

- Explaining why a server feature exists (offline installer, sysext-first design, image updates).
- Deciding whether a new component belongs in the base bootc image or in a standalone `systemd-sysext`.
- Integrating server builds with the downstream CI or image-factory pipeline.
- Onboarding a contributor who asks "what is microraptor for?"

## When NOT to Use

- For desktop variant questions.
- For container image authoring.