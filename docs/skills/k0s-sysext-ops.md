---
name: k0s-sysext-ops
description: Operating k0s on microraptor.
metadata:
  type: how-to
  status: stable
  last_updated: 2026-07-20
---
# k0s Sysext Operations

## When to Use

- Operating k0s on microraptor.
- Runtime operation and reboot coordination for k0s.

## When NOT to Use

- Building the k0s sysext.

## Enabling k0s

On a running microraptor system:

```bash
# 1. Fetch the extension image into persistent k0s staging.
systemd-sysupdate --component=k0s update

# 2. Copy it to the ephemeral sysext scan directory and merge into /usr.
install -D -m 0644 /var/lib/k0s/k0s.raw /run/extensions/k0s.raw
systemd-sysext merge

# 3. Enable and start the controller service
systemctl enable --now k0scontroller.service
```

## Verification

- [ ] `systemd-sysext status` shows k0s as active.
- [ ] `k0s controller status` shows the controller as healthy.
- [ ] `systemctl status k0scontroller.service` shows active.
