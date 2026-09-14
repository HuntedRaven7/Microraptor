---
name: tpm2-credential-sealing
description: TPM2-bound first-boot credentials for the root account.
metadata:
  type: reference
  status: stable
  last_updated: 2026-09-13
---
# TPM2 Credential Sealing

## When to Use

- TPM2-bound first-boot root password provisioning.
- Credential sealing with `systemd-creds` and TPM2.

## Overview

The base DDI ships **no** `/etc/passwd`, `/etc/group`, or `/etc/shadow`
(they are removed from the extra-fs scaffolds at build time). Accounts are
created on first boot by `systemd-sysusers` from
[`files/os/sysusers.d/10-root-creds.conf`](../../files/os/sysusers.d/10-root-creds.conf):

- `root` (uid 0) and `core` (uid 1000), plus the `wheel` group.
- Without a password credential the root account is created **locked**.

The root password is supplied as a systemd credential so it only exists at
rest as an encrypted credential bound to the target machine.

## Flow (first boot)

1. `microraptor-cred-provision.service` (enabled in `sysinit.target.wants` by
   `microraptor-ddi.bst`) runs `microraptor-cred-provision` before
   `systemd-sysusers.service` on `ConditionFirstBoot=yes`.
2. It hashes the root password (default `bluefin`, overridable via
   `microraptor.rootpw=<password>` on the kernel command line) with
   `openssl passwd -6`.
3. With a TPM2 device it writes
   `/etc/credstore.encrypted/passwd.hashed-password.root.cred` using
   `systemd-creds encrypt --with-key=tpm2 --name=passwd.hashed-password.root`.
   The sealed credential is not transferable to another machine.
4. Without a TPM2 device (e.g. QEMU smoke tests) it falls back to a plaintext
   hashed entry at `/etc/credstore/passwd.hashed-password.root`. Only the
   password *hash* is ever stored this way.
5. `systemd-sysusers.service` imports the credential via the drop-in
   [`files/os/cred-provision/system/systemd-sysusers.service.d/50-import-root-credentials.conf`](../../files/os/cred-provision/system/systemd-sysusers.service.d/50-import-root-credentials.conf)
   and applies it when creating the root account.

The console banner (`Default login: root / bluefin`) matches the default
provisioned password.

## Manual usage (sysadmin)

```bash
# Re-seal a custom root password hash to this machine's TPM2
systemd-creds --tpm2-device=auto encrypt s3cret.txt s3cret.cred

# Override the root password on the next first boot via kernel cmdline
#   microraptor.rootpw=my-password
```

## Verification

- [ ] `files/os/sysusers.d/10-root-creds.conf` defines `u root` without a password.
- [ ] `microraptor-ddi.bst` removes `/etc/passwd`/`/etc/group`/`/etc/shadow`
      and enables `systemd-sysusers.service` + `microraptor-cred-provision.service`.
- [ ] `os-stack.bst` includes `components/tpm2-tss.bst`.
- [ ] First boot on TPM hardware creates a credential bound to that TPM2.
- [ ] First boot in a TPM-less VM (QEMU smoke test) falls back to a hashed
      plaintext credential store entry and root can still log in.
- [ ] Credential only takes effect when creating the account (never overrides
      an existing root password).