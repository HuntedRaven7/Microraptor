---
name: avoid-over-engineering
description: Rules and red flags for keeping solutions small.
metadata:
  type: reference
  status: stable
  last_updated: 2026-07-20
---
# Avoid Over-Engineering

## When to Use

- Cutting scope, deleting code, resisting bloat.

## When NOT to Use

- Feature design that genuinely requires complexity.

## Rules

1. Keep changes minimal. The smallest change that solves the problem is best.
2. Remove `TODO/FIXME` and work-in-progress markers before merging.
3. Do not duplicate content across docs.
4. Avoid adding Containerfiles or shell-based installers.
5. Do not hardcode block device paths in boot configuration.
6. Do not put Kubernetes or debug tooling in the base DDI if it can live in a sysext or system container.

## Red Flags

- Adding a workload dependency to `elements/fsdk-it/os-stack.bst` that could ship as a `systemd-sysext`.
- Treating fsdk-it as a generic Fedora/RHEL replacement rather than a factory core OS.
- Putting Kubernetes tooling in the base DDI instead of the k0s sysext.
- Designing install/update paths that require interactive human steps in the factory.

## Verification

- [ ] Any new base-DDI dependency can be justified by the factory core-OS role.
- [ ] Optional capabilities are modeled as sysexts or system containers.
- [ ] The k0s sysext still builds and updates independently of the DDI.
