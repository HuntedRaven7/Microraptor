---
name: bootc-upgrades
description: Image-based updates via bootc from GHCR.
metadata:
  type: reference
  status: stable
  last_updated: 2026-09-15
---
# bootc Upgrades

## When to Use

- Image-based updates and rollbacks via `bootc upgrade` / `bootc rollback`.
- Release trust model for bootc images from GHCR.
- Configuring bootc update policies.

## When NOT to Use

- Package-level updates (not supported).
- `systemd-sysupdate` A/B updates (deprecated).

## Trust model

1. bootc images are published to GHCR (`ghcr.io/<owner>/microraptor:<tag>`).
2. Running systems verify image digests automatically via `bootc upgrade`.
3. Container registry TLS provides transport security; image digests ensure integrity.
4. Optional: cosign/sigstore signatures for additional verification.

## Upgrade workflow

```sh
# Check for updates
bootc status

# Upgrade to latest
sudo bootc upgrade

# Rollback if needed
sudo bootc rollback
```

## Verification

- [ ] Release artifacts include bootc OCI image pushed to GHCR.
- [ ] `bootc upgrade` pulls from GHCR and deploys new version.
- [ ] `bootc rollback` returns to previous deployment.
- [ ] Registry TLS + digest pinning verifies image integrity.
- [ ] Optional cosign/sigstore verification configured.