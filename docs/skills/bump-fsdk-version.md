---
name: bump-fsdk-version
description: Pinning or retagging the FSDK junction.
metadata:
  type: how-to
  status: stable
  last_updated: 2026-07-20
---
# Bump FSDK Version

## When to Use

- Pinning or retagging the FSDK junction.
- Updating the pinned FSDK release and derived tags.

## When NOT to Use

- General dependency updates.

## Procedure

1. Update `elements/freedesktop-sdk.bst` ref to the new FSDK release tag.
2. Update `project.conf` `release-version` to match the new FSDK point release.
3. Run `just validate` to verify the element graph.
4. Run `just build-ddi` to test the build.

## Verification

- [ ] `just validate` passes.
- [ ] `project.conf` `release-version` matches `elements/freedesktop-sdk.bst` ref.
- [ ] Build completes successfully.
