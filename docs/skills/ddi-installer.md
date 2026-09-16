---
name: ddi-installer
description: Use when building or debugging the microraptor bootc installer, or managing the bootc install scripts or target boot configurations.
metadata:
  type: reference
  status: stable
  last_updated: 2026-09-15
  context7-sources:
    - /systemd/systemd
    - /apache/buildstream
---
# DDI Installer (bootc)

## When to Use

- Building or debugging the microraptor bootc live installer media.
- Writing or refining `systemd-repart`, `bootctl`, or `ukify` configurations.
- Packaging or publishing installer assets to GitHub Releases.
- Managing partition recipes for the target disk layout (`bootc-target-10-esp.conf`, `bootc-target-20-root.conf`).
- Working with the shell-based `bootc-install.sh` wrapper.

## When NOT to Use

- OCI-only image work (no installer involvement).
- A/B `systemd-sysupdate` changes (replaced by `bootc upgrade`).
- Desktop or nspawn machine image work.
- Adding network DDI fetching — the bootc image is embedded as an OCI-dir in the installer media.

## Architecture

The installer is offline, self-contained, and uses a shell-based installer script. The bootc OCI image
(`microraptor-bootc.bst`) is exported as an OCI-dir layout and embedded as a data partition on the installer
media at build time. No network access is required at install time.

The installer UI is a custom shell script (`bootc-install.sh`) that:
- Prompts for the target disk (selected interactively or on the command line).
- Validates target disk size and suitability.
- Runs `bootc install to-disk` with the embedded OCI image as source.
- Seeds the k0s sysext from the installer media to the target `/var/lib/extensions/`.
- Registers the bootloader (`systemd-boot`) via bootc's internal logic.
- Reboots into the installed system.

## Partition Layout

### Installer media (the USB/raw disk image)

| Partition | Type | Size | Contents |
|---|---|---|---|
| ESP | vfat | 512 MiB fixed | `EFI/BOOT/BOOTX64.EFI` (UKI) |
| `microraptor-installer-data` | XFS | auto | bootc OCI image as oci-dir |

### Target disk (after install)

| Partition | Type | Size | Contents |
|---|---|---|---|
| ESP | vfat | 512 MiB | `systemd-boot` + target OS UKI (managed by bootc) |
| `Microraptor-root` | XFS | remaining | OS root filesystem (bootc deployment) |

## Verification

- [ ] `just validate` resolves the BuildStream graph without errors.
- [ ] No `systemd-sysinstall` service units exist in the codebase.
- [ ] UKI boot cmdline points to `systemd.unit=system-install.target`.
- [ ] Serial console `console=ttyS0,115200` is the final console argument in the installer UKI cmdline.
- [ ] `installer-stack.bst` explicitly includes XFS and vfat support.
- [ ] `microraptor-installer-bootc.bst` overrides `systemd-sysinstall.service`
      with `SuccessAction=poweroff`/`FailureAction=poweroff` for clean shutdown.
- [ ] `microraptor-installer-bootc.bst` exports the bootc OCI image as oci-dir and embeds it via `CopyBlocks=`.
- [ ] `files/installer/repart.d/bootc-target-20-root.conf` has `GrowFileSystem=yes`.

## Target OS boot notes

The target UKI cmdline and bootc installation follow these rules:

- bootc manages the root filesystem deployment and bootloader entries.
- The installed system uses bootc's native partition layout (DPS GUIDs).
- Updates are performed via `bootc upgrade` pulling from GHCR.
- No A/B root partitions; single root with in-place upgrades.