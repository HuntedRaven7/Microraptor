kind: script
description: |
  Produce the microraptor bootc live installer disk image.

  Output: microraptor-installer-<ver>.raw.zst + SHA256SUMS

  Offline installer: the bootc OCI image is embedded as a data partition on
  the installer media. No network required at install time.

  Initrd approach: dracut-free, cpio-native.
  The installer-stack rootfs is packed directly into a cpio.zst initrd using
  POSIX find + cpio. No initrd generator is needed - systemd PID 1 works
  correctly when the initrd is a plain rootfs cpio with /init -> systemd.

  The installer UI is a shell script (bootc-install.sh) that:
  - Detects the target disk
  - Runs bootc install to-disk with the embedded OCI image
  - Seeds k0s sysext if present
  - Reboots

  Build pipeline:
    1. Add /init symlink + mount points
    2. Link default.target -> system-install.target
    3. Pack rootfs as newc cpio + gzip -> installer.cpio.gz
    4. ukify build: kernel + cpio.gz -> installer.efi (unsigned UKI)
    5. Export bootc OCI image as oci-dir and embed into /layer for repart
    6. systemd-repart --empty=create: assemble two-partition GPT disk
       (ESP with UKI + data partition with embedded OCI image)
    7. Compress final disk as .raw.zst + SHA256SUMS for GitHub Releases

build-depends:
  # Toolchain for assembly
  - base/base-stack.bst
  - freedesktop-sdk.bst:components/binutils.bst
  - freedesktop-sdk.bst:components/dracut.bst
  - freedesktop-sdk.bst:components/kmod.bst
  - freedesktop-sdk.bst:components/cpio.bst
  - freedesktop-sdk.bst:components/findutils.bst
  - freedesktop-sdk.bst:components/gzip.bst
  - freedesktop-sdk.bst:components/grep.bst
  - freedesktop-sdk.bst:components/sed.bst
  - freedesktop-sdk.bst:components/zstd.bst
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
  # bootc OCI image staged at /bootc-image - embedded into the installer media data partition
  - filename: oci/microraptor-bootc.bst
    config:
      location: /bootc-image-raw
  # Uncompressed k0s sysext staged into the installer initrd for offline install
  - filename: oci/k0s-sysext.bst
    config:
      location: /k0s

variables:
  installer-version: "%{release-version}"

config:
  commands:
    # -- Step 1a: Prepare the initrd rootfs -------------------------------
    - |
      set -eux
      # Ensure critical tools are present in the staged rootfs before packing
      for tool in udevadm lsblk systemd-repart bootctl; do
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
      mkdir -p /layer/boot/EFI/Linux /tmp /var/tmp

    # -- Step 1b: Stage installer kernel from target rootfs -------------------
    - |
      set -eux
      INSTALLER_KVER="$(basename "$(find /layer/usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")"
      if [ -z "${INSTALLER_KVER}" ]; then
        echo "ERROR: no kernel module tree found under /layer/usr/lib/modules" >&2
        exit 1
      fi
      echo "Staged installer kernel ${INSTALLER_KVER} from installer stack"

    # -- Step 1c: Generate target OS UKI (dracut + ukify) ----------------
    - |
      set -eux
      TARGET_KVER="$(basename "$(find /bootc-image-raw/usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")"
      if [ -z "${TARGET_KVER}" ]; then
        echo "ERROR: no kernel module tree found under /bootc-image-raw/usr/lib/modules" >&2
        exit 1
      fi
      TARGET_KERNEL="/bootc-image-raw/boot/vmlinuz"
      if [ ! -f "${TARGET_KERNEL}" ]; then
        TARGET_KERNEL="/bootc-image-raw/usr/lib/modules/${TARGET_KVER}/vmlinuz"
      fi
      if [ ! -f "${TARGET_KERNEL}" ]; then
        echo "ERROR: target kernel is missing at /bootc-image-raw/boot/vmlinuz or /bootc-image-raw/usr/lib/modules/${TARGET_KVER}/vmlinuz" >&2
        exit 1
      fi
      mkdir -p /layer/boot
      ln -sf "/usr/lib/modules/${TARGET_KVER}/vmlinuz" /layer/boot/vmlinuz 2>/dev/null || true

      depmod -b /bootc-image-raw "${TARGET_KVER}" || true
      ldconfig || true

      TARGET_KERNEL_SYSROOT="${TARGET_KERNEL#/bootc-image-raw}"
      : "${TARGET_KERNEL_SYSROOT:=/boot/vmlinuz}"

      # dracut needs its runtime libraries in the target root to resolve dependencies.
      # Copy dracut's runtime files to target root.
      mkdir -p "/bootc-image-raw/usr/lib/dracut"
      cp -a /usr/lib/dracut/* "/bootc-image-raw/usr/lib/dracut/"

      dracut -v --reproducible --no-machineid --no-hostonly \
         --add-drivers "virtio virtio_blk virtio_pci virtio_scsi nvme nvme_core ahci libata sd_mod mmc_core mmc_block sdhci sdhci_acpi cqhci uas usb-storage xfs erofs overlay iwlwifi iwldvm iwlmvm ath9k ath10k ath11k mt7921e mt7925e rtl8xxxu" \
        --filesystems "xfs vfat" \
        --kmoddir "/bootc-image-raw/usr/lib/modules/${TARGET_KVER}" \
        --kernel-image "${TARGET_KERNEL_SYSROOT}" \
        --kver "${TARGET_KVER}" \
        --kernel-cmdline "ro root=PARTLABEL=Microraptor-root rootwait rootfstype=xfs rd.debug console=ttyS0,115200 console=tty0 systemd.debug_shell=tty9" \
        /tmp/microraptor-target.initramfs

      mkdir -p /tmp/initrd-strip
      cd /tmp/initrd-strip
      zstd -d /tmp/microraptor-target.initramfs -o /tmp/microraptor-target.cpio
      cpio -id < /tmp/microraptor-target.cpio

      # dracut omits most shared libraries (including glibc) from this initrd.
      # Without them the kernel cannot exec /init in the initramfs and the
      # system panics at the first boot. Resolve every DT_NEEDED soname used
      # by the initrd and inject the missing libraries from the target rootfs.
      initrd_lib_fix() {
        local soname="$1" real="" d=""
        for d in /bootc-image-raw/lib /bootc-image-raw/lib64 \
                 /bootc-image-raw/lib/x86_64-linux-gnu /bootc-image-raw/usr/lib/x86_64-linux-gnu \
                 /bootc-image-raw/usr/lib /bootc-image-raw/usr/lib64 \
                 /lib/x86_64-linux-gnu /usr/lib/x86_64-linux-gnu /lib /lib64 /usr/lib /usr/lib64; do
          if [ -e "${d}/${soname}" ]; then
            real="${d}/${soname}"
            break
          fi
        done
        [ -n "${real}" ] || return 0
        mkdir -p usr/lib usr/lib64 usr/lib/x86_64-linux-gnu
        cp -aLT "${real}" "usr/lib/${soname}"
        cp -aLT "${real}" "usr/lib64/${soname}"
        cp -aLT "${real}" "usr/lib/x86_64-linux-gnu/${soname}"
        local dep
        for dep in $(readelf -d "${real}" 2>/dev/null \
                      | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
          case "${dep}" in
            ld-linux*|ld-*.so|libc.so.6|libm.so.6|libdl.*|libpthread.*) continue ;;
            *\.so*) [ -e "usr/lib/${dep}" ] || initrd_lib_fix "${dep}" ;;
          esac
        done
      }
      for f in $(find . -type f -o -type l); do
        case "${f}" in
          *\.so*|*systemd|*/bin/*|*/sbin/*|*/usr/libexec/*|*/usr/lib/systemd/*) ;;
          *) continue ;;
        esac
        for dep in $(readelf -d "${f}" 2>/dev/null \
                      | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
          case "${dep}" in
            ld-linux*|ld-*.so) continue ;;
            *\.so*) [ -e "usr/lib/${dep}" ] || initrd_lib_fix "${dep}" ;;
          esac
        done
      done
      if ! [ -e usr/lib/libc.so.6 ]; then
        echo "ERROR: libc.so.6 not injected into initrd" >&2
        exit 1
      fi

      # dracut emits a self-referential systemd-udevd symlink, which makes
      # systemd-udevd unexecutable. Without udev no block device is ever
      # discovered and first boot hangs forever on the root device.
      # Mirror the working layout: udevadm is the multi-call binary.
      if [ -L usr/lib/systemd/systemd-udevd ] \
           && [ "$(readlink usr/lib/systemd/systemd-udevd)" = "/usr/lib/systemd/systemd-udevd" ]; then
        ln -sfn ../../bin/udevadm usr/lib/systemd/systemd-udevd
      fi
      if ! [ -x usr/bin/udevadm ] \
           || [ "$(readlink -f usr/lib/systemd/systemd-udevd)" != "$(pwd)/usr/bin/udevadm" ]; then
        echo "ERROR: systemd-udevd not resolved to udevadm in initrd" >&2
        exit 1
      fi

      # systemd 261 ships initrd-parse-etc.service with
      # ExecStart=/usr/lib/systemd/systemd-sysroot-fstab-check, but FSDK's
      # dracut does not install the multi-call symlink into the initramfs.
      # Without it initrd-parse-etc fails right after the root filesystem
      # mounts cleanly and systemd drops into emergency mode on every boot.
      # Install the same symlink the systemd package ships on disk: the
      # fstab-generator binary dispatches on its invocation name.
      if ! [ -e usr/lib/systemd/systemd-sysroot-fstab-check ]; then
        ln -sfn system-generators/systemd-fstab-generator usr/lib/systemd/systemd-sysroot-fstab-check
      fi
      if ! [ -L usr/lib/systemd/systemd-sysroot-fstab-check ]; then
        echo "ERROR: systemd-sysroot-fstab-check symlink not installed in initrd" >&2
        exit 1
      fi

      # Stage the offline k0s sysext into the installer initrd so the var
      # partition can seed it without network at install time.
      cp /k0s/k0s-*.raw /layer/k0s.raw
      ls -lh /layer/k0s.raw

      find . | cpio -o -H newc | gzip -9 > /tmp/microraptor-target.initramfs

      SBAT=$'sbat,1,SBAT Version,sbat,1,https://github.com/rhboot/shim/blob/main/SBAT.md\nuki.author.microraptor,1,Microraptor,uki.author.microraptor,1,https://github.com/HuntedRaven7/microraptor'

      ukify build \
        --linux="${TARGET_KERNEL}" \
        --initrd=/tmp/microraptor-target.initramfs \
        --sbat="${SBAT}" \
        --cmdline="ro root=PARTLABEL=Microraptor-root rootwait rootfstype=xfs rd.debug console=ttyS0,115200 console=tty0 systemd.debug_shell=tty9" \
        --output=/layer/boot/EFI/Linux/microraptor.efi

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
      for tool in udevadm lsblk systemd-repart bootctl; do
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

    # -- Step 1e: Install bootc-install.sh wrapper script ------------------
    - |
      set -eux
      # Copy the bootc installer wrapper script
      cp /var/home/robin/git/personal/Microraptor/files/installer/bootc-install.sh /layer/usr/bin/microraptor-sysinstall
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

    # -- Step 1f: Finalize installer target --------------------------------
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
      rm -f /layer/usr/lib/systemd/system/default.target
      ln -sf system-install.target \
        /layer/usr/lib/systemd/system/default.target

    # -- Step 2: Pack initrd cpio -----------------------------------------
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

    # -- Step 3: Build the installer UKI --------------------------------------------
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

    # -- Step 4: Export bootc OCI image as oci-dir for embedding ---------------
    - |
      set -eu
      # Export the bootc OCI image as oci-dir layout
      mkdir -p /bootc-image
      skopeo copy oci:/bootc-image-raw oci-dir:/bootc-image
      ls -la /bootc-image

    # -- Step 5: Assemble installer GPT disk image ------------------------
    # Two-partition layout:
    #   bootc-installer-10-esp.conf: ESP (512M) - UKI lives here; boots the installer
    #   bootc-installer-20-data.conf: Data (XFS) - bootc-image oci-dir copied here
    - |
      set -eu
      OUT="%{install-root}"
      FNAME="microraptor-installer-%{installer-version}.raw"
      mkdir -p /installer-media-repart.d

      cat > /installer-media-repart.d/bootc-installer-10-esp.conf << 'RCONF'
      [Partition]
      Type=esp
      Format=vfat
      Label=Microraptor-installer-esp
      CopyFiles=/boot/efi:/
      SizeMinBytes=512M
      SizeMaxBytes=512M
      RCONF

      cat > /installer-media-repart.d/bootc-installer-20-data.conf << 'RCONF'
      [Partition]
      Type=linux-generic
      Label=microraptor-installer-data
      Format=xfs
      CopyBlocks=/bootc-image
      RCONF

      systemd-repart \
        --empty=create \
        --size=auto \
        --dry-run=no \
        --root=/layer \
        --definitions=/installer-media-repart.d \
        "${OUT}/${FNAME}"
      ls -lh "${OUT}/${FNAME}"

    # -- Step 6: Compress and generate SHA256SUMS ------------------------
    - |
      set -eux
      cd "%{install-root}"
      FNAME="microraptor-installer-%{installer-version}.raw"
      zstd --rm -T0 -19 -q "${FNAME}" -o "${FNAME}.zst"

      # Also export the target UKI (.efi) for GitHub Releases and PXE
      cp /layer/boot/EFI/Linux/microraptor.efi "microraptor-%{installer-version}.efi"
      # Export raw PXE inputs alongside the UKI
      INSTALLER_KVER="$(basename "$(find /layer/usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")"
      cp "/layer/usr/lib/modules/${INSTALLER_KVER}/vmlinuz" "microraptor-pxe-vmlinuz-%{installer-version}"
      cp /installer.cpio.gz "microraptor-pxe-initrd-%{installer-version}.cpio.gz"

      sha256sum --binary "${FNAME}.zst" > SHA256SUMS
      sha256sum --binary "microraptor-%{installer-version}.efi" >> SHA256SUMS
      sha256sum --binary "microraptor-pxe-vmlinuz-%{installer-version}" >> SHA256SUMS
      sha256sum --binary "microraptor-pxe-initrd-%{installer-version}.cpio.gz" >> SHA256SUMS
      ls -lh