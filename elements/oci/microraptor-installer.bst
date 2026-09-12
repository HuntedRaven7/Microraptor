kind: script
description: |
  Produce the microraptor DDI live installer disk image.

  Output: microraptor-installer-<ver>.raw.zst + SHA256SUMS

  Offline installer: the OS DDI payload is embedded as a data partition on
  the installer media. No network required at install time.

  Initrd approach: dracut-free, cpio-native.
  The installer-stack rootfs is packed directly into a cpio.zst initrd using
  POSIX find + cpio. No initrd generator is needed - systemd PID 1 works
  correctly when the initrd is a plain rootfs cpio with /init -> systemd.
  This is the approach the systemd project uses for its own test images.

  The installer UI is systemd-sysinstall, a native systemd terminal-based
  interactive installer. It prompts for the target disk, partitions it using
  systemd-repart, copies the XFS DDI filesystem, registers the boot loader via
  bootctl, and reboots.

  Build pipeline:
    1. Add /init symlink + mount points
    2. Link default.target -> system-install.target
    3. Pack rootfs as newc cpio + gzip -> installer.cpio.gz
    4. ukify build: kernel + cpio.gz -> installer.efi (unsigned UKI)
    5. Decompress DDI payload into /layer for embedding (after cpio, not in initrd)
    6. systemd-repart --empty=create: assemble two-partition GPT disk
       (ESP with UKI + data partition with embedded DDI payload)
    7. Compress final disk as .raw.zst + SHA256SUMS for GitHub Releases

build-depends:
  # Toolchain for assembly
  - base/base-stack.bst
  - freedesktop-sdk.bst:components/dracut.bst
  - freedesktop-sdk.bst:components/kmod.bst
  - freedesktop-sdk.bst:components/cpio.bst      # newc cpio archive creation
  - freedesktop-sdk.bst:components/findutils.bst  # find for cpio pipe
  - freedesktop-sdk.bst:components/gzip.bst       # compress initrd
  # grep/sed are required by dracut/dracut-install even though our commands don't name them.
  - freedesktop-sdk.bst:components/grep.bst
  - freedesktop-sdk.bst:components/sed.bst
  - freedesktop-sdk.bst:components/zstd.bst       # compress initrd + final disk
  # ukify assembles the UKI (kernel + initrd + cmdline -> .efi)
  - freedesktop-sdk.bst:components/systemd-ukify.bst
  # systemd-repart assembles the GPT installer disk image
  - freedesktop-sdk.bst:components/systemd.bst
  - freedesktop-sdk.bst:components/dosfstools.bst
  - freedesktop-sdk.bst:components/mtools.bst
  # Installer live-env rootfs staged at /layer
  - filename: installer/installer-stack.bst
    config:
      location: /layer
  # OS DDI payload staged at /ddi - embedded into the installer media data partition
  - filename: oci/microraptor-ddi.bst
    config:
      location: /ddi
  - filename: microraptor/os-rootfs.bst
    config:
      location: /target-root

variables:
  installer-version: "%{release-version}"

config:
  commands:
    # -- Step 1a: Prepare the initrd rootfs -------------------------------
    - |
      set -eux
      # Ensure critical tools are present in the staged rootfs before packing
      for tool in udevadm lsblk systemd-repart bootctl systemd-sysinstall; do
        if ! [ -x "/layer/usr/bin/${tool}" ] && ! [ -x "/layer/usr/sbin/${tool}" ]; then
          echo "ERROR: Critical tool '${tool}' is missing from the staged rootfs at /layer!" >&2
          exit 1
        fi
      done

      # systemd-native initrd: /init -> PID 1
      cat > /layer/init << 'EOF'
      #!/bin/sh
      echo "init: starting systemd"
      exec /usr/lib/systemd/systemd
      EOF
      chmod +x /layer/init
      # Mount points needed by the installer service
      mkdir -p /layer/efi /layer/mnt/esp /layer/mnt/root /layer/run/installer
      mkdir -p /layer/usr/lib/microraptor
      mkdir -p /target-root/boot/EFI/Linux /tmp /var/tmp

    # -- Step 1b: Stage installer kernel from target rootfs -------------------
    - |
      set -eux
      INSTALLER_KVER="$(basename "$(find /target-root/usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")"
      if [ -z "${INSTALLER_KVER}" ]; then
        echo "ERROR: no kernel module tree found under /target-root/usr/lib/modules" >&2
        exit 1
      fi
      mkdir -p /layer/usr/lib/modules
      cp -a "/target-root/usr/lib/modules/${INSTALLER_KVER}" /layer/usr/lib/modules/
      echo "Staged installer kernel ${INSTALLER_KVER} from target rootfs"

    # -- Step 1c: Generate target OS UKI (dracut + ukify) ----------------
    - |
      set -eux
      TARGET_KVER="$(basename "$(find /target-root/usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")"
      if [ -z "${TARGET_KVER}" ]; then
        echo "ERROR: no kernel module tree found under /target-root/usr/lib/modules" >&2
        exit 1
      fi
      TARGET_KERNEL="/target-root/boot/vmlinuz"
      if [ ! -f "${TARGET_KERNEL}" ]; then
        TARGET_KERNEL="/target-root/usr/lib/modules/${TARGET_KVER}/vmlinuz"
      fi
      if [ ! -f "${TARGET_KERNEL}" ]; then
        echo "ERROR: target kernel is missing at /target-root/boot/vmlinuz or /target-root/usr/lib/modules/${TARGET_KVER}/vmlinuz" >&2
        exit 1
      fi
      mkdir -p /target-root/boot
      ln -sf "/usr/lib/modules/${TARGET_KVER}/vmlinuz" /target-root/boot/vmlinuz 2>/dev/null || true

      depmod -b /target-root "${TARGET_KVER}" || true
      ldconfig || true

      TARGET_KERNEL_SYSROOT="${TARGET_KERNEL#/target-root}"
      : "${TARGET_KERNEL_SYSROOT:=/boot/vmlinuz}"

      # dracut needs its runtime libraries in the target root to resolve dependencies.
      # Copy dracut's runtime files to target root.
      mkdir -p "/target-root/usr/lib/dracut"
      cp -a /usr/lib/dracut/* "/target-root/usr/lib/dracut/"

      dracut -v --reproducible --no-machineid --no-hostonly \
         --add-drivers "virtio virtio_blk virtio_pci virtio_scsi nvme nvme_core ahci libata sd_mod mmc_core mmc_block sdhci sdhci_acpi cqhci uas usb-storage xfs erofs overlay iwldvm iwlmvm ath9k ath10k ath11k mt7921 mt7922 mt7925 rtl8xxxu" \
        --filesystems "xfs vfat" \
        --kmoddir "/target-root/usr/lib/modules/${TARGET_KVER}" \
        --kernel-image "${TARGET_KERNEL_SYSROOT}" \
        --kver "${TARGET_KVER}" \
        --kernel-cmdline "rw root=PARTLABEL=Microraptor-root-a rootwait rootfstype=xfs rd.debug console=ttyS0,115200 console=tty0" \
        /tmp/microraptor-target.initramfs

      mkdir -p /tmp/initrd-strip
      cd /tmp/initrd-strip
      zstd -d /tmp/microraptor-target.initramfs -o /tmp/microraptor-target.cpio
      cpio -id < /tmp/microraptor-target.cpio
      find . | cpio -o -H newc | gzip -9 > /tmp/microraptor-target.initramfs

      SBAT=$'sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md\nuki.author.microraptor,1,Microraptor,uki.author.microraptor,1,https://github.com/HuntedRaven7/microraptor'

      ukify build \
        --linux="${TARGET_KERNEL}" \
        --initrd=/tmp/microraptor-target.initramfs \
        --sbat="${SBAT}" \
        --cmdline="rw root=PARTLABEL=Microraptor-root-a rootwait rootfstype=xfs rd.debug console=ttyS0,115200 console=tty0" \
        --output=/target-root/boot/EFI/Linux/microraptor.efi
      cp /target-root/boot/EFI/Linux/microraptor.efi /layer/usr/lib/microraptor/microraptor.efi

    # -- Step 1d: Configure installer services and users ------------------
    - |
      set -eux
      INSTALLER_KVER="$(basename "$(find /layer/usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")"
      if [ -z "${INSTALLER_KVER}" ]; then
        echo "ERROR: no installer kernel module tree found under /layer/usr/lib/modules" >&2
        exit 1
      fi
      mkdir -p /layer/boot
      if [ ! -f /layer/boot/vmlinuz ]; then
        ln -sf "../usr/lib/modules/${INSTALLER_KVER}/vmlinuz" /layer/boot/vmlinuz
      fi

      # Ensure critical tools are present in the staged rootfs before packing
      for tool in udevadm lsblk systemd-repart bootctl systemd-sysinstall; do
        if ! [ -x "/layer/usr/bin/${tool}" ] && ! [ -x "/layer/usr/sbin/${tool}" ]; then
          echo "ERROR: Critical tool '${tool}' is missing from the staged rootfs at /layer!" >&2
          exit 1
        fi
      done

      # System users for networkd/resolved
      printf 'systemd-network:x:998:998:systemd Network Management:/run/systemd:/usr/sbin/nologin\nsystemd-resolve:x:997:997:systemd Resolver:/run/systemd:/usr/sbin/nologin\n' >> /layer/etc/passwd
      printf 'systemd-network:x:998:\nsystemd-resolve:x:997:\n' >> /layer/etc/group

      # Enable sysusers plus the services needed on the live installer target.
      mkdir -p /layer/usr/lib/systemd/system/sysinit.target.wants
      ln -sf /usr/lib/systemd/system/systemd-sysusers.service \
        /layer/usr/lib/systemd/system/sysinit.target.wants/systemd-sysusers.service
      mkdir -p /layer/usr/lib/systemd/system/system-install.target.wants
      ln -sf /usr/lib/systemd/system/systemd-networkd.service \
        /layer/usr/lib/systemd/system/system-install.target.wants/systemd-networkd.service
      ln -sf /usr/lib/systemd/system/systemd-resolved.service \
        /layer/usr/lib/systemd/system/system-install.target.wants/systemd-resolved.service

      # Mask systemd-firstboot to prevent interactive credential blocks on tty1
      mkdir -p /layer/etc/systemd/system
      ln -sf /dev/null /layer/etc/systemd/system/systemd-firstboot.service

      # Prevent screen from turning off when laptop lid closes
      mkdir -p /layer/etc/systemd/logind.conf.d
      printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\n' > /layer/etc/systemd/logind.conf.d/noclose.conf

    # -- Step 1d: Configure installer services and users ------------------
    - |
      set -eux
      # Write the installer wrapper script
      cat > /layer/usr/bin/microraptor-sysinstall << 'EOF'
      #!/bin/sh
      set -eu

      # Ensure NVMe, SATA, USB, eMMC/SD, and WiFi modules are loaded
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

      echo "==> Enumerating block devices for target disk..."
      lsblk -p -d -n -o NAME,TYPE,RM,SIZE -b 2>&1 || true
      echo "==> MMC/eMMC kernel messages (dmesg):"
      dmesg 2>/dev/null | grep -iE 'mmc|emmc|sdhci|rk3399|cqhci|k3|mobicore' || true
      echo "==> Storage driver modules loaded:"
      lsmod 2>/dev/null | grep -iE 'mmc|sdhci|sd_mod' || true
      echo "==> Storage devices in /dev:"
      ls -la /dev/mmc* /dev/sd* /dev/nvme* /dev/vd* 2>/dev/null || true
      echo "==> WiFi kernel messages (dmesg):"
      dmesg 2>/dev/null | grep -iE 'wifi|wlan|iwl|ath|mt792|rtl8|cfg80211|mac80211' || true
      echo "==> WiFi driver modules loaded:"
      lsmod 2>/dev/null | grep -iE 'iwl|ath|mt792|rtl8|cfg80211|mac80211' || true
      echo "==> WiFi devices in /dev:"
      ls -la /dev/null /dev/tty* /dev/rfkill 2>/dev/null || true

      TARGET_DISK=""
      INSTALLER_PART="$(readlink -f /dev/disk/by-partlabel/microraptor-installer-data 2>/dev/null || true)"

      while read -r name type rm size; do
        [ "${type}" = "disk" ] || continue
        [ "${rm}" = "0" ] || continue
        [ "${size}" -gt 0 ] || continue

        case "${INSTALLER_PART}" in
          "${name}"*) continue ;;
        esac

        TARGET_DISK="${name}"
        break
      done < <(lsblk -p -d -n -o NAME,TYPE,RM,SIZE -b)

      if [ -z "${TARGET_DISK}" ]; then
        while read -r name type rm size; do
          [ "${type}" = "disk" ] || continue
          [ "${size}" -gt 0 ] || continue

          case "${INSTALLER_PART}" in
            "${name}"*) continue ;;
          esac

          TARGET_DISK="${name}"
          break
        done < <(lsblk -p -d -n -o NAME,TYPE,SIZE -b)
      fi


      CMDLINE="$(< /proc/cmdline)"
      case " ${CMDLINE} " in
        *" unattended "*)
          echo "==> Running in UNATTENDED mode..."
          if [ -n "${TARGET_DISK}" ]; then
            echo "==> Auto-detected target disk: ${TARGET_DISK}"
            echo "==> Calling systemd-sysinstall on ${TARGET_DISK}..."
            lsblk -p -n -l -o NAME,FSTYPE,SIZE,LABEL "${TARGET_DISK}" || true
             /usr/bin/systemd-sysinstall \
               --kernel=/usr/lib/microraptor/microraptor.efi \
               --erase=yes \
               --confirm=no \
               --summary=no \
               --variables=yes \
               --reboot=no \
               "${TARGET_DISK}" < /dev/null
             echo "==> systemd-sysinstall returned: $?"
             echo "==> Logging repart.d definitions for debug:"
             ls -la /layer/usr/lib/repart.d/ 2>/dev/null || true
             for f in /layer/usr/lib/repart.d/*.conf; do
               echo "==> repart config: ${f}"
               sed -n '1,120p' "${f}" 2>/dev/null || true
             done
             echo "==> Logging final install summary to ESP..."
             {
               echo "microraptor install log: $(date -u)"
               echo "TARGET_DISK=${TARGET_DISK}"
               echo "INSTALLER_KVER=${INSTALLER_KVER}"
               TARGET_KVER="$(basename "$(find /target-root/usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")" || true
               echo "TARGET_KVER=${TARGET_KVER}"
               echo "==> Post-install partition table:"
               lsblk -p -n -l -o NAME,FSTYPE,SIZE,LABEL,TYPE "${TARGET_DISK}" || true
               echo "==> Verifying root partition..."
               ROOT_PART="$(readlink -f /dev/disk/by-partlabel/Microraptor-root-a 2>/dev/null || true)"
               if [ -n "${ROOT_PART}" ] && [ -b "${ROOT_PART}" ]; then
                 echo "==> Root partition found at ${ROOT_PART}"
                 mkdir -p /mnt/verify-root
                 if mount -t xfs "${ROOT_PART}" /mnt/verify-root; then
                   echo "==> Root filesystem mounted successfully"
                   ls -la /mnt/verify-root/ | head -20
                   umount /mnt/verify-root || true
                 else
                   echo "==> ERROR: Failed to mount root filesystem on ${ROOT_PART}" >&2
                 fi
               else
                 echo "==> ERROR: Root partition Microraptor-root-a not found!" >&2
               fi
               echo "==> Boot entries:"
               bootctl list 2>/dev/null || true
             } 2>&1 | tee /layer/installer-log.txt || true
             mkdir -p /layer/boot/efi/EFI/Linux 2>/dev/null || true
             cp /layer/installer-log.txt /layer/boot/efi/EFI/Linux/installer-log.txt 2>/dev/null || true
          else
            echo "ERROR: No suitable target disk found for unattended installation!" >&2
            exit 1
          fi
          ;;
        *)
          echo "==> Running in INTERACTIVE mode..."
          /usr/bin/systemd-sysinstall \
            --kernel=/usr/lib/microraptor/microraptor.efi \
            --variables=yes \
            --reboot=no \
            --copy-locale=yes \
            --copy-keymap=yes \
            --copy-timezone=yes
          ;;
      esac

      # Ensure bootloader is installed (systemd-sysinstall --kernel= should do this,
      # but run explicitly as fallback)
      ensure_bootloader() {
        echo "==> Ensuring bootloader is installed..."
        udevadm settle --timeout=10 || true
        ROOT_PART="$(readlink -f /dev/disk/by-partlabel/Microraptor-root-a 2>/dev/null || true)"
        ESP_PART="$(readlink -f /dev/disk/by-partlabel/Microraptor-ESP 2>/dev/null || true)"
        if [ -z "${ROOT_PART}" ] || [ -z "${ESP_PART}" ]; then
          echo "==> ensure_bootloader: partitions not found, skipping" >&2
          return 0
        fi
        mkdir -p /mnt/root
        if mount -t xfs "${ROOT_PART}" /mnt/root; then
          mkdir -p /mnt/root/boot/efi
          if mount -t vfat "${ESP_PART}" /mnt/root/boot/efi; then
            if [ -f /usr/lib/microraptor/microraptor.efi ]; then
              mkdir -p /mnt/root/boot/efi/EFI/Linux
              cp /usr/lib/microraptor/microraptor.efi /mnt/root/boot/efi/EFI/Linux/microraptor.efi
              echo "==> ensure_bootloader: copied UKI to ESP"
            fi
            echo "==> ensure_bootloader: installing systemd-boot..."
            if bootctl install --esp-path=/mnt/root/boot/efi --root=/mnt/root; then
              echo "==> ensure_bootloader: bootctl install succeeded"
              bootctl list 2>/dev/null || true
            else
              echo "==> ensure_bootloader: bootctl install FAILED" >&2
            fi
            umount /mnt/root/boot/efi || true
          else
            echo "==> ensure_bootloader: failed to mount ESP ${ESP_PART}" >&2
          fi
          umount /mnt/root || true
        else
          echo "==> ensure_bootloader: failed to mount root ${ROOT_PART}" >&2
        fi
      }

      ensure_bootloader

      interactive_setup() {
        local root_part=""
        root_part="$(readlink -f /dev/disk/by-partlabel/Microraptor-root-a 2>/dev/null || true)"
        if [ -z "${root_part}" ] || [ ! -b "${root_part}" ]; then
          echo "==> interactive_setup: root partition not found, skipping" >&2
          return 0
        fi

        local mnt="/mnt/root"
        mkdir -p "${mnt}"
        if ! mount -t xfs "${root_part}" "${mnt}"; then
          echo "==> interactive_setup: failed to mount root" >&2
          return 0
        fi

        trap 'umount "${mnt}" >/dev/null 2>&1 || true' EXIT

        choose_quadlets "${mnt}"

        umount "${mnt}" || true
        trap - EXIT
      }

      choose_quadlets() {
        local mnt="$1"
        local quadlet_src="/usr/share/microraptor/quadlets"
        local quadlet_dst="${mnt}/etc/containers/systemd"
        local tmp_sel
        local selected
        local choices=()
        local idx=0

        mkdir -p "${quadlet_dst}"

        for f in "${quadlet_src}"/*.quadlet; do
          [ -f "${f}" ] || continue
          choices+=("${f}" "$(basename "${f}")" "on")
          idx=$(( idx + 1 ))
        done

        if [ "${idx}" -eq 0 ]; then
          echo "==> choose_quadlets: no quadlets available"
          return 0
        fi

        selected="$(whiptail --separate-output --checklist "Select podman quadlets to install" 20 70 10 "${choices[@]}" 3>&1 1>&2 2>&3 3>&1 || true)"
        if [ -z "${selected}" ]; then
          return 0
        fi

        mkdir -p "${quadlet_dst}"
        for src in ${selected}; do
          cp -a "${src}" "${quadlet_dst}/"
          echo "==> choose_quadlets: installed $(basename "${src}")"
        done
      }

      interactive_setup

      echo "==> Installation complete! Rebooting..."
      systemctl reboot
      EOF
      chmod +x /layer/usr/bin/microraptor-sysinstall

      # DHCP on all ethernet interfaces in the installer live environment
      mkdir -p /layer/etc/systemd/network
      printf '[Match]\nName=en* eth* ens* enp*\n\n[Network]\nDHCP=yes\n' \
        > /layer/etc/systemd/network/80-dhcp.network
      chmod 755 /layer/usr/lib/systemd/network 2>/dev/null || true
      cp /layer/etc/systemd/network/80-dhcp.network /layer/usr/lib/systemd/network/ 2>/dev/null || true

      mkdir -p /layer/etc/systemd/system/systemd-sysinstall.service.d
      cat > /layer/etc/systemd/system/systemd-sysinstall.service.d/override.conf << 'EOF'
      [Unit]
      After=systemd-udev-settle.service
      Wants=systemd-udev-settle.service
      SuccessAction=poweroff
      FailureAction=poweroff

      [Service]
      ExecStart=
      ExecStart=/usr/bin/microraptor-sysinstall
      EOF

    # -- Step 1e: Installer wrapper script and network config --------------
    - |
      set -eu
      if [ ! -f /layer/usr/lib/systemd/system/system-install.target ]; then
        echo "ERROR: system-install.target is missing from the staged rootfs! FSDK systemd must be version 261 or later." >&2
        exit 1
      fi
      if [ ! -L /layer/usr/lib/systemd/system/system-install.target.wants/systemd-sysinstall.service ]; then
        echo "ERROR: system-install.target.wants/systemd-sysinstall.service is missing from the staged rootfs! FSDK systemd must be built with -Dsysinstall=true." >&2
        exit 1
      fi
      if [ ! -f /layer/usr/lib/microraptor/microraptor.efi ]; then
        echo "ERROR: target UKI is missing from the staged rootfs!" >&2
        exit 1
      fi
      rm -f /layer/usr/lib/systemd/system/default.target
      ln -sf system-install.target \
        /layer/usr/lib/systemd/system/default.target

    # -- Step 2: Wire default.target -> system-install.target ------------
    # find . from /layer gives paths like ./usr/bin/... which is exactly
    # the newc format the kernel expects. The kernel strips the leading dot.
    - |
      set -eux
      export PATH="/usr/bin:/bin:/usr/sbin:/sbin"

      # Clean up bloat from /layer before packing (reduces initrd size!)
      rm -rf /layer/usr/lib/debug /layer/usr/share/doc /layer/usr/share/man /layer/usr/include
      rm -rf /layer/usr/share/locale /layer/usr/share/i18n
      find /layer -type f -name '*.debug' -delete
      find /layer -type f -name '*.a' -delete

      # Strip unneeded large kernel modules (GPU, wireless, sound, media, bluetooth)
      KVER=$(ls /layer/usr/lib/modules | head -1)
      if [ -n "${KVER}" ]; then
        rm -f "/layer/usr/lib/modules/${KVER}/vmlinux" "/layer/usr/lib/modules/${KVER}/System.map"
        MOD_DIR="/layer/usr/lib/modules/${KVER}/kernel"
        if [ -d "${MOD_DIR}" ]; then
          rm -rf "${MOD_DIR}/drivers/gpu"
          rm -rf "${MOD_DIR}/drivers/net/wireless"
          rm -rf "${MOD_DIR}/drivers/sound" "${MOD_DIR}/sound"
          rm -rf "${MOD_DIR}/drivers/media"
          rm -rf "${MOD_DIR}/drivers/bluetooth"
          rm -rf "${MOD_DIR}/drivers/infiniband"
        fi
        # Re-run depmod to update module dependencies after stripping unneeded modules
        depmod -b /layer "${KVER}" || true
      fi

      ( cd /layer && find . -print0 \
          | /usr/bin/cpio --null --create --format=newc ) \
        | /usr/bin/gzip -9 -c > /installer.cpio.gz
      ls -lh /installer.cpio.gz
      ls -lh /installer.cpio.gz

    # -- Step 3: Pack initrd cpio -----------------------------------------
    # Unsigned UKI - acceptable for USB installer media. Secure Boot
    # signing can be layered on by passing --secureboot-private-key /
    # --secureboot-certificate if keys are injected at CI time.
    - |
      set -eux
      mkdir -p /layer/boot/efi/EFI/BOOT
      INSTALLER_KVER="$(basename "$(find /layer/usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")"
      INSTALLER_KERNEL="/layer/boot/vmlinuz"
      if [ ! -f "${INSTALLER_KERNEL}" ]; then
        INSTALLER_KERNEL="/layer/usr/lib/modules/${INSTALLER_KVER}/vmlinuz"
      fi
      if [ ! -f "${INSTALLER_KERNEL}" ]; then
        echo "ERROR: installer kernel is missing at /layer/boot/vmlinuz or /layer/usr/lib/modules/${INSTALLER_KVER}/vmlinuz" >&2
        exit 1
      fi
      SBAT=$'sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md\nuki.author.microraptor,1,Microraptor,uki.author.microraptor,1,https://github.com/HuntedRaven7/microraptor'

      ukify build \
        --linux="${INSTALLER_KERNEL}" \
        --initrd=/installer.cpio.gz \
        --sbat="${SBAT}" \
         --cmdline="systemd.unit=system-install.target console=tty0 rw rd.systemd.debug-shell=1 loglevel=7" \
        --output=/layer/boot/efi/EFI/BOOT/BOOTX64.EFI
      ls -lh /layer/boot/efi/EFI/BOOT/BOOTX64.EFI

    # -- Step 4: Build the UKI --------------------------------------------
    # This runs AFTER the initrd cpio is packed (Step 3), so the DDI is NOT
    # included in the initrd. It is placed in /layer temporarily so that
    # systemd-repart's CopyBlocks= (which resolves paths under --root=/layer)
    # can copy it into the installer media data partition.
    - |
      set -eu
      zstd -d /ddi/microraptor-ddi-*.raw.zst -o /layer/microraptor-ddi.raw
      ls -lh /layer/microraptor-ddi.raw

    # -- Step 5: Decompress DDI payload for embedding ---------------------
    # Two-partition layout:
    #   10-esp.conf:      ESP (1G) - UKI lives here; boots the installer
    #   20-ddi-data.conf: Data (XFS) - microraptor-ddi.raw copied here block-for-block
    - |
      set -eu
      OUT="%{install-root}"
      FNAME="microraptor-installer-%{installer-version}.raw"
      mkdir -p /installer-media-repart.d

      cat > /installer-media-repart.d/10-esp.conf << 'RCONF'
      [Partition]
      Type=esp
      Format=vfat
      CopyFiles=/boot/efi:/
      SizeMinBytes=2G
      SizeMaxBytes=2G
      RCONF

      cat > /installer-media-repart.d/20-ddi-data.conf << 'RCONF'
      [Partition]
      Type=linux-generic
      Label=microraptor-installer-data
      CopyBlocks=/microraptor-ddi.raw
      RCONF

      systemd-repart \
        --empty=create \
        --size=auto \
        --dry-run=no \
        --root=/layer \
        --definitions=/installer-media-repart.d \
        "${OUT}/${FNAME}"
      ls -lh "${OUT}/${FNAME}"

      # Clean up DDI from /layer - it's now in the installer media partition.
      rm -f /layer/microraptor-ddi.raw

    # -- Step 6: Assemble installer GPT disk image ------------------------
    - |
      set -eux
      cd "%{install-root}"
      FNAME="microraptor-installer-%{installer-version}.raw"
      zstd --rm -T0 -19 -q "${FNAME}" -o "${FNAME}.zst"

      # Also export the target UKI (.efi) for GitHub Releases and systemd-sysupdate
      cp /layer/usr/lib/microraptor/microraptor.efi "microraptor-%{installer-version}.efi"
      # Export raw PXE inputs alongside the UKI. PXE users supply their own
      # kernel command line, so these remain separate from the fixed-cmdline UKI.
      INSTALLER_KVER="$(basename "$(find /layer/usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")"
      cp "/layer/usr/lib/modules/${INSTALLER_KVER}/vmlinuz" "microraptor-pxe-vmlinuz-%{installer-version}"
      cp /installer.cpio.gz "microraptor-pxe-initrd-%{installer-version}.cpio.gz"

      sha256sum --binary "${FNAME}.zst" > SHA256SUMS
      sha256sum --binary "microraptor-%{installer-version}.efi" >> SHA256SUMS
      sha256sum --binary "microraptor-pxe-vmlinuz-%{installer-version}" >> SHA256SUMS
      sha256sum --binary "microraptor-pxe-initrd-%{installer-version}.cpio.gz" >> SHA256SUMS
      ls -lh
