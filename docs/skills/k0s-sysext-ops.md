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
# Trigger systemd-sysupdate to pull the k0s systemd-sysext if missing
systemd-sysupdate update || true

# Setup k0s configuration directory
install -d -m 0755 /etc/k0s

# Trigger systemd-sysext to merge extensions into /usr immediately
systemctl enable --now systemd-sysext.service || true
systemd-sysext merge || true

# Enable and start the controller service
systemctl enable --now k0scontroller.service
```

## Verification

- [ ] `systemd-sysext status` shows k0s as active.
- [ ] `k0s controller status` shows the controller as healthy.
- [ ] `systemctl status k0scontroller.service` shows active.
