---
name: index
description: Lazy-load manifest for microraptor skills. Load this file after AGENTS.md, then read only the skill that matches your current task.
metadata:
  type: index
  status: stable
  last_updated: 2026-07-20
---
# docs/skills — Index

This is the lazy-load routing table for agent skills. Keep this file in memory while you work; load only the skill file named in each row.

## Routing table

| Skill file | When to load | One-line scope |
|---|---|---|
| [`avoid-over-engineering.md`](avoid-over-engineering.md) | Cutting scope, deleting code, resisting bloat | Rules and red flags for keeping solutions small. |
| [`architecture-roadmap.md`](architecture-roadmap.md) | Future architecture direction, long-lead design | Roadmap for systemd-native architecture work. |
| [`bump-fsdk-version.md`](bump-fsdk-version.md) | Pinning or retagging the FSDK junction | Update the pinned FSDK release and derived tags. |
| [`ci-tooling.md`](ci-tooling.md) | GitHub Actions, workflow SHA pinning, CI conventions | CI conventions and release pipeline rules. |
| [`ddi-installer.md`](ddi-installer.md) | Installer boot flow, `systemd-sysinstall`, `systemd-repart` | High-level DDI install architecture and local smoke test. |
| [`ddi-installer-build.md`](ddi-installer-build.md) | Building the installer or DDI on the cluster | Cluster build pipeline and local installer/DDI build. |
| [`factory-integration.md`](factory-integration.md) | Lab integration, boot-test workflow, factory role | How microraptor is consumed by the CI lab. |
| [`gap-analysis-distros.md`](gap-analysis-distros.md) | Comparing microraptor to other server OSes | Source-verified comparison to Ubuntu, Talos, Flatcar, FCOS. |
| [`k0s-sysext.md`](k0s-sysext.md) | Building the k0s sysext | BuildStream element and publish steps for the k0s sysext. |
| [`k0s-sysext-ops.md`](k0s-sysext-ops.md) | Operating k0s on microraptor | Runtime operation and reboot coordination for k0s. |
| [`skill-improvement.md`](skill-improvement.md) | Adding, splitting, or refactoring skills | Meta-skill that owns the documentation loop. |
| [`podman-quadlets-sysext.md`](podman-quadlets-sysext.md) | Building the podman-quadlets sysext | BuildStream element and publish steps for the podman-quadlets sysext. |
| [`podman-quadlets.md`](podman-quadlets.md) | Working with Podman quadlets on microraptor | Podman quadlet deployment and management. |
| [`system-containers.md`](system-containers.md) | Running `systemd-nspawn` toolboxes | System container operation with `machinectl`. |
| [`systemd-sysext-extensions.md`](systemd-sysext-extensions.md) | Optional layers via `systemd-sysext` / `systemd-confext` | Extension identity, loading, and Flatcar compatibility. |
| [`systemd-sysupdate-verification.md`](systemd-sysupdate-verification.md) | Image-based A/B updates and signed manifests | Release signing, `systemd-sysupdate`, and trust model. |
| [`tpm2-credential-sealing.md`](tpm2-credential-sealing.md) | TPM2-bound first-boot credentials | Credential sealing with `systemd-creds` and TPM2. |

## Standing facts

- **Publish registry:** factory OCI registry (set by your operator).
- **Cluster build workflow:** `microraptor-build-pipeline` in the downstream factory CI repository.
- **Cluster boot-test workflow:** `microraptor-boot-test` in the downstream factory CI repository.
- **Version scheme:** FSDK-derived only; no separate application version axis.
