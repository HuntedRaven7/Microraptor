"""Contracts for the published bootc Installer and headless smoke boot."""

from __future__ import annotations

import re
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
INSTALLER_STACK = REPO_ROOT / "elements" / "installer" / "installer-stack.bst"
INSTALLER_ELEMENT = (
    REPO_ROOT / "elements" / "oci" / "microraptor-installer-bootc.bst"
)
JUSTFILE = REPO_ROOT / "Justfile"
BOOTC_ELEMENT = REPO_ROOT / "elements" / "oci" / "microraptor-bootc.bst"


def _published_uki_cmdline(installer_element: str) -> str:
    match = re.search(
        r'ukify build\s+.*?--cmdline="([^"]+)"\s+'
        r"[ \t\\\r\n]+--output=/layer/boot/efi/EFI/BOOT/BOOTX64\.EFI",
        installer_element,
        flags=re.DOTALL,
    )
    assert match, "published Installer UKI ukify command must be present"
    return match.group(1)


def _target_uki_cmdline(installer_element: str) -> str:
    match = re.search(
        r'ukify build\s+.*?--cmdline="([^"]+)"\s+'
        r"[ \t\\\r\n]+--output=/layer/boot/EFI/Linux/microraptor\.efi",
        installer_element,
        flags=re.DOTALL,
    )
    assert match, "target UKI ukify command must be present"
    return match.group(1)


def test_installer_runtime_and_boot_contracts() -> None:
    installer_stack = INSTALLER_STACK.read_text(encoding="utf-8")
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")
    justfile = JUSTFILE.read_text(encoding="utf-8")
    published_uki_cmdline = _published_uki_cmdline(installer_element)
    target_uki_cmdline = _target_uki_cmdline(installer_element)

    assert "console=tty0 rw" in published_uki_cmdline
    assert "unattended" not in published_uki_cmdline
    assert target_uki_cmdline.startswith("ro root=PARTLABEL=Microraptor-root")
    assert "rootwait rootfstype=xfs rd.debug console=ttyS0,115200 console=tty0 systemd.debug_shell=tty9" in target_uki_cmdline
    assert (
        'systemd.unit=system-install.target '
        'console=tty0 console=ttyS0,115200 rw unattended'
    ) in justfile


def test_installer_wrapper_reads_kernel_command_line_without_cat() -> None:
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")

    assert 'CMDLINE="$(< /proc/cmdline)"' in installer_element
    assert 'CMDLINE="$(cat /proc/cmdline' not in installer_element


def test_installer_stages_uncompressed_k0s_before_packing_cpio() -> None:
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")
    data = yaml.safe_load(installer_element)
    k0s_dependency = next(
        (
            dependency
            for dependency in data["build-depends"]
            if isinstance(dependency, dict)
            and dependency.get("filename") == "oci/k0s-sysext.bst"
        ),
        None,
    )

    assert k0s_dependency == {
        "filename": "oci/k0s-sysext.bst",
        "config": {"location": "/k0s"},
    }

    seed_command = "cp /k0s/k0s-*.raw /layer/k0s.raw"
    cpio_command = "| /usr/bin/cpio --null --create --format=newc"
    assert seed_command in installer_element
    assert installer_element.index(seed_command) < installer_element.index(
        cpio_command
    )


def test_bootc_image_generates_module_indexes_for_runtime_filesystem_drivers() -> None:
    bootc_element = BOOTC_ELEMENT.read_text(encoding="utf-8")

    assert "gnome-build-meta.bst:gnomeos-deps/bootc.bst" in bootc_element
    assert "prepare-image.sh" in bootc_element
    assert "systemd-sysusers --root /layer" in bootc_element
    assert "ldconfig -r /layer -f /layer/etc/ld.so.conf" in bootc_element
    assert "build-oci" in bootc_element
    assert "containers.bootc" in bootc_element
    assert "org.opencontainers.image.ref.name" in bootc_element


def test_target_initramfs_preloads_sysext_filesystem_drivers() -> None:
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")

    assert (
        '--add-drivers "virtio virtio_blk virtio_pci virtio_scsi nvme nvme_core ahci libata sd_mod mmc_core mmc_block sdhci sdhci_acpi cqhci uas usb-storage xfs erofs overlay iwlwifi iwldvm iwlmvm ath9k ath10k ath11k mt7921e mt7925e rtl8xxxu"'
        in installer_element
    )


def test_installer_loads_storage_drivers_and_settles_udev() -> None:
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")

    assert "modprobe -q nvme || true" in installer_element
    assert "modprobe -q nvme_core || true" in installer_element
    assert "modprobe -q ahci || true" in installer_element
    assert "modprobe -q libata || true" in installer_element
    assert "modprobe -q sd_mod || true" in installer_element
    assert "modprobe -q mmc_core || true" in installer_element
    assert "modprobe -q mmc_block || true" in installer_element
    assert "modprobe -q sdhci || true" in installer_element
    assert "modprobe -q sdhci_acpi || true" in installer_element
    assert "modprobe -q cqhci || true" in installer_element
    assert "modprobe -q uas || true" in installer_element
    assert "modprobe -q usb-storage || true" in installer_element
    assert "modprobe -q iwldvm || true" in installer_element
    assert "modprobe -q iwlmvm || true" in installer_element
    assert "modprobe -q ath9k || true" in installer_element
    assert "modprobe -q ath10k || true" in installer_element
    assert "modprobe -q ath11k || true" in installer_element
    assert "modprobe -q mt7921 || true" in installer_element
    assert "modprobe -q mt7922 || true" in installer_element
    assert "modprobe -q mt7925 || true" in installer_element
    assert "modprobe -q rtl8xxxu || true" in installer_element
    assert "udevadm settle --timeout=15 || true" in installer_element
    assert "After=systemd-udev-settle.service" in installer_element
    assert "Wants=systemd-udev-settle.service" in installer_element


def test_installer_and_bootc_strip_vmlinux_and_static_archives() -> None:
    installer_element = INSTALLER_ELEMENT.read_text(encoding="utf-8")
    bootc_element = BOOTC_ELEMENT.read_text(encoding="utf-8")

    assert 'rm -f "/layer/usr/lib/modules/${KVER}/vmlinux"' in installer_element
    assert "find /layer -type f -name '*.a' -delete" in installer_element
    # bootc element uses prepare-image.sh which runs depmod
    assert "depmod" in bootc_element