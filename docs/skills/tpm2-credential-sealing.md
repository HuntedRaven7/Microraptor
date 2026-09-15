---
name: tpm2-credential-sealing
description: Securing provisioning credentials (such as operator SSH keys via tmpfiles.extra) with TPM2 sealing via systemd-creds.
metadata:
  type: reference
  status: stable
  last_updated: 2026-09-14
---
# TPM2 Credential Sealing

## When to Use

- TPM2-bound first-boot operator SSH key provisioning.
- Credential sealing with `systemd-creds` and TPM2.

## Overview

The base DDI ships **no** `/etc/passwd`, `/etc/group`, or `/etc/shadow`
(they are removed from the extra-fs scaffolds at build time). Accounts are
created on first boot by `systemd-sysusers` from
[`files/os/sysusers.d/10-root-creds.conf`](../../files/os/sysusers.d/10-root-creds.conf)
and [`files/os/sysusers.d/10-core-user.conf`](../../files/os/sysusers.d/10-core-user.conf):

- `root` (uid 0) — no password, no shell access.
- `core` (uid 1000) — operator account with passwordless sudo.

SSH access is key-only for the `core` operator account. The authorized SSH
keys are provisioned via the `tmpfiles.extra` systemd credential, written
into persistent `/var/home/core/.ssh/authorized_keys`.

## Flow (first boot)

1. The installer or hypervisor provides the `tmpfiles.extra` credential via
   the ESP at `/loader/credentials/tmpfiles.extra.cred` or via
   `--set-credential=tmpfiles.extra:/path/to/cred`.
2. `systemd-tmpfiles-setup.service` applies the credential, creating the
   `/var/home/core` home tree and writing the authorized keys.
3. `bluefin-core-access.service` verifies that
   `/var/home/core/.ssh/authorized_keys` exists and is non-empty.
4. `sshd` starts only after the core authorization gate passes.

The sealed credential ensures that unauthorized keys cannot be injected into
the machine offline when TPM2 protection is active.

## Encrypt and seal a credential

The `tmpfiles.extra` credential payload establishes directory ownership and
writes the authorized SSH keys for the `core` operator account:

```
d /var/home/core 0700 core core -
d /var/home/core/.ssh 0700 core core -
f~ /var/home/core/.ssh/authorized_keys 0600 core core - c3NoLWVkMjU1MTkgQUFBQUMzTnphQzFsWkRJMU5UR...
```

The base64 data in the `f~` line is an SSH public key, not a secret. Sealing
the credential ensures that unauthorized keys cannot be injected into the
machine offline when TPM2 protection is active.

Seal the credential against PCR 7 (Secure Boot state) and PCR 11 (Unified Kernel
Image state) on the TPM2 chip:

```bash
systemd-creds encrypt \
  --name=tmpfiles.extra \
  --with-key=tpm2 \
  --tpm2-pcrs=7+11 \
  /path/to/plaintext_tmpfiles_extra.txt \
  /path/to/secured_credential.cred
```

- `--name=` must match the credential name the consumer expects
  (`tmpfiles.extra` is read by `systemd-tmpfiles`).
- `--with-key=tpm2` forces a TPM2-bound credential. The default `auto` also
  uses the host key if `/var/lib/systemd/` is on persistent media; omit the
  switch if you want both bindings.

## Provide the encrypted credential to the host

Place the output `.cred` file in the ESP credential directory or pass it via a
container/hypervisor mechanism. The credential file is
`/loader/credentials/tmpfiles.extra.cred` on the target ESP:

```bash
# ESP delivery
mkdir -p /loader/credentials/
cp /path/to/secured_credential.cred /loader/credentials/tmpfiles.extra.cred

# Or via a container/hypervisor argument
--set-credential=tmpfiles.extra:/path/to/secured_credential.cred
```

## Offline recovery sequence

There is no fallback password or root SSH bypass. If the `core` key is lost or
unusable, SSH fails closed. The supported offline recovery sequence requires
physical access or equivalent hypervisor access:

1. Shut down the target host.
2. Mount the target ESP from a trusted machine.
3. Replace `/loader/credentials/tmpfiles.extra.cred` on the ESP with a
   credential that writes the replacement `core` public key.
4. Boot the host. `systemd-tmpfiles` applies the credential, `bluefin-core-access`
   verifies key readiness, and `sshd` starts.
5. Authenticate as `core` (`ssh core@server.example`) and elevate using `sudo -i`.

## Verification

- [ ] `files/os/sysusers.d/10-core-user.conf` defines the `core` operator account.
- [ ] `files/os/tmpfiles.d/10-core-home.conf` creates the home and `.ssh` tree.
- [ ] `files/os/systemd/system/bluefin-core-access.service` gates `sshd` on key readiness.
- [ ] `files/os/ssh/sshd_config.d/microraptor.conf` disables root and password auth.
- [ ] First boot with a valid `tmpfiles.extra` credential creates `/var/home/core/.ssh/authorized_keys`.
- [ ] First boot without the credential leaves `sshd` disabled (fails closed).

## See also

- [CONTEXT.md](../../CONTEXT.md) — canonical project domain glossary.
- [factory-integration.md](factory-integration.md) — operator login and remote diagnostics.
- `systemd-creds(1)`
- `systemd.system-credentials(7)`