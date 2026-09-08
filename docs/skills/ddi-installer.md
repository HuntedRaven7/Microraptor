---
name: ddi-installer
description: Use when building or debugging the microraptor DDI live installer, or managing the systemd-sysinstall recipes or target boot configurations.
metadata:
  type: reference
  status: stable
  last_updated: 2026-07-20
  context7-sources:
    - /systemd/systemd
    - /apache/buildstream
---
# DDI Installer

## When to Use

- Building or debugging the microraptor live installer media.
- Writing or refining `systemd-repart`, `bootctl`, or `ukify` configurations.
- Packaging or publishing DDI assets to GitHub Releases.
- Managing partition recipes for the target disk layout (`10-esp.conf`,
  `20-root-a.conf`, `30-var.conf`).

## When NOT to Use

- OCI-only image work (no installer involvement).
- Bootc-specific changes.
- Desktop or nspawn machine image work.
- Adding network DDI fetching — the DDI remains embedded as a data partition.

## Architecture

The installer is offline, self-contained, and systemd-native. The OS DDI payload
(`microraptor-ddi.bst`) is embedded as a data partition on the installer
media at build time. No network access is required at install time.

The installer UI is systemd's built-in `systemd-sysinstall` which provides a
terminal-based interactive installation that:

- Prompts for the target disk (selected interactively or on the command line).
- Validates target disk size and suitability.
- Offers to erase the target disk or install alongside existing partitions.
- Copies the OS filesystem DDI block-for-block using `systemd-repart` and
  partition recipes (`CopyBlocks=`).
- Registers the bootloader (`systemd-boot`) and the Unified Kernel Image (UKI)
  using `bootctl`.
- Propagates installer environment settings (locale, keymap, timezone) to the
  target OS via encrypted credentials.
- Reboots into the installed system.

## Partition Layout

### Installer media (the USB/raw disk image)

| Partition | Type | Size | Contents |
|---|---|---|---|
| ESP | vfat | 1 GiB fixed | `EFI/BOOT/BOOTX64.EFI` + `EFI/Linux/installer.efi` (UKI) |
| `microraptor-installer-data` | XFS | auto | OS filesystem DDI image, copied block-for-block |

### Target disk (after install)

| Partition | Type | Size | Contents |
|---|---|---|---|
| ESP | vfat | 500 MiB – 1 GiB | `systemd-boot` + target OS UKI (`microraptor.efi`) |
| `microraptor-root-a` | XFS | 4 GiB – 16 GiB | OS root filesystem (copied from installer data partition) |
| `var` | XFS | ≥ 4 GiB | Writable persistent `/var`; grows to fill remaining disk |

## Verification

- [ ] `just validate` resolves the BuildStream graph without errors.
- [ ] No custom installer service units exist in the codebase.
- [ ] UKI boot cmdline points to `systemd.unit=system-install.target`.
- [ ] Serial console `console=ttyS0,115200` is the final console argument in the installer UKI cmdline.
- [ ] `installer-stack.bst` explicitly includes XFS and vfat support.
- [ ] `microraptor-installer.bst` overrides `systemd-sysinstall.service`
      with `SuccessAction=poweroff`/`FailureAction=poweroff` for clean shutdown.
- [ ] `microraptor-installer.bst` decompresses the DDI after the cpio step.
- [ ] `files/installer/repart.d/20-root-a.conf` has `GrowFileSystem=yes`.
