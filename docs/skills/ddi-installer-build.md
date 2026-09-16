---
name: ddi-installer-build
description: Building the bootc installer or OCI image on the cluster.
metadata:
  type: reference
  status: stable
  last_updated: 2026-09-15
---
# DDI Installer Build (bootc)

## When to Use

- Building the bootc installer or OCI image on the cluster.
- Cluster build pipeline and local installer/OCI build.

## When NOT to Use

- Day-to-day development work.

## Build commands

| Command | Purpose |
|---|---|
| `just validate` | Merge-contract graph check — run this on every change. |
| `just build-bootc` | Local bootc OCI image build. |
| `just export-bootc` | Export bootc OCI image to podman. |
| `just build-installer-bootc` | Local full installer build. |
| `just export-installer-bootc` | Export installer + UKI to `dist/`. |
| `just show-me-the-future` | Local QEMU installer smoke test. |

## Verification

- [ ] `just validate` passes.
- [ ] All artifacts build successfully.
- [ ] Exported artifacts are present in `dist/`.