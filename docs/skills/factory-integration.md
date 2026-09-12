---
name: factory-integration
description: Understand microraptor's role as the core OS for an image-based CI/OS factory and how optional workloads run on it.
metadata:
  type: reference
  status: stable
  last_updated: 2026-07-20
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
| Fully automated, unattended installs | Offline DDI installer (`systemd-sysinstall`) |
| Atomic, rollback-capable updates | Image-based A/B updates via `systemd-sysupdate` |
| Minimal attack surface / no shell in OS | Distroless DDI; optional tools as sysexts |
| Kubernetes control plane on every node | k3s delivered as `systemd-sysext` |
| Signed, verifiable release artifacts | GPG-signed `SHA256SUMS` + `import-pubring.gpg` |

## SSH and standard server administration

> `sshd` is included for standard server administration. Root login is permitted with key-based auth only (see [`files/os/ssh/sshd_config.d/microraptor.conf`](files/os/ssh/sshd_config.d/microraptor.conf)). The lab runs the `microraptor-boot-test` workflow (in the downstream factory CI repository) to verify installer → first-boot success.

## When to Use

- Explaining why a server feature exists (offline installer, sysext-first design, image updates).
- Deciding whether a new component belongs in the base DDI or in a standalone `systemd-sysext`.
- Integrating server builds with the downstream CI or image-factory pipeline.
- Onboarding a contributor who asks "what is microraptor for?"

## When NOT to Use

- For desktop variant questions.
- For container image authoring.
- For lab operational troubleshooting.

## Common Rationalizations

| Rationalization | Reality |
|---|---|
| "k3s should be in the base image." | Keep the OS DDI minimal. k3s is optional and delivered OTA as a sysext. |
| "We can pull the DDI at install time." | Unattended installs must survive network loss; the DDI is embedded in the installer media. |
| "Let's add a shell for debugging." | Shells belong in sysexts or system containers, not in the distroless DDI. SSH is included for standard server administration with key-based auth. |
| "Package updates are small patches." | Image-based updates are whole-OS replacements; the rollback unit is the OS image, not a package delta. |

## Red Flags

- Adding a workload dependency to `elements/microraptor/os-stack.bst` that could ship as a `systemd-sysext`.
- Treating microraptor as a generic Fedora/RHEL replacement rather than the factory core OS.
- Putting Kubernetes tooling in the base DDI instead of the k3s sysext.
- Designing install/update paths that require interactive human steps in the factory.

## Verification

- [ ] Any new base-DDI dependency can be justified by the factory core-OS role.
- [ ] Optional capabilities are modeled as sysexts or system containers.
- [ ] The k3s sysext still builds and updates independently of the DDI.
- [ ] `systemd-sysupdate` transfer files are present for every OTA-delivered artifact (DDI, UKI, k3s sysext).
