---
name: ddi-installer-build
description: Building the installer or DDI on the cluster.
metadata:
  type: reference
  status: stable
  last_updated: 2026-07-20
---
# DDI Installer Build

## When to Use

- Building the installer or DDI on the cluster.
- Cluster build pipeline and local installer/DDI build.

## When NOT to Use

- Day-to-day development work.

## Build commands

| Command | Purpose |
|---|---|
| `just validate` | Merge-contract graph check — run this on every change. |
| `just build-ddi` | Local OS DDI payload build. |
| `just export-ddi` | Export DDI artifacts to `dist/ddi/`. |
| `just build-installer` | Local full installer build. |
| `just export-installer` | Export installer + UKI to `dist/`. |
| `just show-me-the-future` | Local QEMU installer smoke test. |

## Verification

- [ ] `just validate` passes.
- [ ] All artifacts build successfully.
- [ ] Exported artifacts are present in `dist/`.
