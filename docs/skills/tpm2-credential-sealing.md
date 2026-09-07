---
name: tpm2-credential-sealing
description: TPM2-bound first-boot credentials.
metadata:
  type: reference
  status: stable
  last_updated: 2026-07-20
---
# TPM2 Credential Sealing

## When to Use

- TPM2-bound first-boot credentials.
- Credential sealing with `systemd-creds` and TPM2.

## When NOT to Use

- Non-TPM systems.

## Overview

First-boot credentials can be sealed to the TPM2 so they are only decryptable on the same physical system. This is useful for provisioning secrets like root passwords or SSH keys that should not be transferable between devices.

## Usage

```bash
# Seal a credential to the local TPM2
systemd-creds --tpm2-device=auto encrypt my-secret.txt my-secret.cred

# Decrypt on first boot
systemd-creds decrypt my-secret.cred
```

## Verification

- [ ] Credentials are sealed successfully.
- [ ] Decryption works on the same TPM2 device.
- [ ] Decryption fails on a different TPM2 device.
