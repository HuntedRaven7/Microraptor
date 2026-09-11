---
name: ci-tooling
description: GitHub Actions, workflow SHA pinning, CI conventions.
metadata:
  type: reference
  status: stable
  last_updated: 2026-07-20
---
# CI Tooling

## When to Use

- GitHub Actions, workflow SHA pinning, CI conventions.

## When NOT to Use

- Local development commands.

## Conventions

- All workflows use action SHA pinning for security.
- `contents: read` is the default permission; write is granted per job only where required.
- Build jobs run on `ubuntu-24.04`.
- Concurrency groups cancel in-progress runs.

## Key workflows

- `.github/workflows/build.yml` — builds DDI, installer, and k0s sysext artifacts.
- `.github/workflows/build-local.yml` — same build targets but ignores all remote BuildStream caches; use when `gbm.gnome.org:11003` or `cache.projectbluefin.io:11001` are unreachable.

## Verification

- [ ] All workflow actions are SHA-pinned.
- [ ] `actionlint` passes on all workflow files.
