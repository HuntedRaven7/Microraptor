#!/bin/bash
# shellcheck disable=SC2317
set -euo pipefail

# Microraptor bootc installer
# Runs in the installer live environment, installs the bootc image to target disk

INSTALLER_DATA_LABEL="microraptor-installer-data"
INSTALLER_ESP_LABEL="microraptor-installer-esp"

log() {
    echo "==> $*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

detect_target_disk() {
    local installer_part=""
    installer_part="$(readlink -f "/dev/disk/by-partlabel/${INSTALLER_DATA_LABEL}" 2>/dev/null || true)"

    local target_disk=""
    while read -r name type rm size; do
        [ "${type}" = "disk" ] || continue
        [ "${rm}" = "0" ] || continue
        [ "${size}" -gt 0 ] || continue

        case "${installer_part}" in
            "${name}"*) continue ;;
        esac

        target_disk="${name}"
        break
    done < <(lsblk -p -d -n -o NAME,TYPE,RM,SIZE -b)

    if [ -z "${target_disk}" ]; then
        while read -r name type rm size; do
            [ "${type}" = "disk" ] || continue
            [ "${size}" -gt 0 ] || continue

            case "${installer_part}" in
                "${name}"*) continue ;;
            esac

            target_disk="${name}"
            break
        done < <(lsblk -p -d -n -o NAME,TYPE,SIZE -b)
    fi

    echo "${target_disk}"
}

run_unattended() {
    local target_disk="$1"
    log "Running in UNATTENDED mode..."
    log "Auto-detected target disk: ${target_disk}"
    lsblk -p -n -l -o NAME,FSTYPE,SIZE,LABEL "${target_disk}" || true

    if [ ! -f "/usr/lib/microraptor/bootc-image" ]; then
        die "bootc image OCI directory not found at /usr/lib/microraptor/bootc-image"
    fi
    log "bootc image found at /usr/lib/microraptor/bootc-image"

    log "Installing to ${target_disk} via bootc..."
    bootc install to-disk \
        --wipe \
        --source-imgref "oci:/usr/lib/microraptor/bootc-image" \
        --target-imgref "ghcr.io/HuntedRaven7/microraptor:latest" \
        --bootloader systemd \
        --filesystem xfs \
        --karg "console=ttyS0,115200" \
        --karg "console=tty0" \
        --karg "systemd.firstboot=no" \
        "${target_disk}"

    log "bootc install completed successfully"
}

run_interactive() {
    local target_disk="$1"
    log "Running in INTERACTIVE mode..."
    log "Target disk: ${target_disk}"

    if [ ! -f "/usr/lib/microraptor/bootc-image" ]; then
        die "bootc image OCI directory not found at /usr/lib/microraptor/bootc-image"
    fi

    bootc install to-disk \
        --source-imgref "oci:/usr/lib/microraptor/bootc-image" \
        --target-imgref "ghcr.io/HuntedRaven7/microraptor:latest" \
        --bootloader systemd \
        --filesystem xfs \
        --karg "console=ttyS0,115200" \
        --karg "console=tty0" \
        --karg "systemd.firstboot=no" \
        "${target_disk}"

    log "bootc install completed successfully"
}

seed_k0s_sysext() {
    local target_root="$1"
    local k0s_raw="/k0s.raw"

    if [ -f "${k0s_raw}" ]; then
        log "Seeding k0s sysext to target /var/lib/extensions..."
        mkdir -p "${target_root}/var/lib/extensions"
        cp "${k0s_raw}" "${target_root}/var/lib/extensions/k0s.raw"
        log "k0s sysext seeded"
    else
        log "k0s.raw not found, skipping sysext seeding"
    fi
}

main() {
    log "Microraptor bootc installer starting..."

    modprobe -q nvme || true
    modprobe -q nvme_core || true
    modprobe -q ahci || true
    modprobe -q libata || true
    modprobe -q sd_mod || true
    modprobe -q mmc_core || true
    modprobe -q mmc_block || true
    modprobe -q sdhci || true
    modprobe -q sdhci_acpi || true
    modprobe -q cqhci || true
    modprobe -q uas || true
    modprobe -q usb-storage || true
    modprobe -q iwldvm || true
    modprobe -q iwlmvm || true
    modprobe -q ath9k || true
    modprobe -q ath10k || true
    modprobe -q ath11k || true
    modprobe -q mt7921 || true
    modprobe -q mt7922 || true
    modprobe -q mt7925 || true
    modprobe -q rtl8xxxu || true
    udevadm settle --timeout=15 || true

    log "Enumerating block devices for target disk..."
    lsblk -p -d -n -o NAME,TYPE,RM,SIZE -b 2>&1 || true

    local target_disk
    target_disk="$(detect_target_disk)"

    if [ -z "${target_disk}" ]; then
        die "No suitable target disk found for installation!"
    fi

    local cmdline
    cmdline="$(< /proc/cmdline)"
    case " ${cmdline} " in
        *" unattended "*)
            run_unattended "${target_disk}"
            ;;
        *)
            run_interactive "${target_disk}"
            ;;
    esac

    local root_part
    root_part="$(readlink -f /dev/disk/by-partlabel/Microraptor-root 2>/dev/null || true)"
    if [ -n "${root_part}" ] && [ -b "${root_part}" ]; then
        log "Mounting target root to seed k0s sysext..."
        local mnt="/mnt/target-root"
        mkdir -p "${mnt}"
        if mount -t xfs "${root_part}" "${mnt}"; then
            seed_k0s_sysext "${mnt}"
            umount "${mnt}" || true
        else
            log "WARNING: Failed to mount target root partition"
        fi
    fi

    log "Installation complete! Rebooting..."
    systemctl reboot
}

main "$@"