# List available commands
[group('info')]
default:
    @just --list

# Same bst2 container image FSDK/dakota CI uses -- pinned by SHA.
export bst2_image := env("BST2_IMAGE", "registry.gitlab.com/freedesktop-sdk/infrastructure/freedesktop-sdk-docker-images/bst2:64eb0b4930d57a92710822898fb73af6cc1ae35d")

# Prefix for podman calls: empty when rootless podman works, "sudo" otherwise.
sudo_cmd := if `podman info >/dev/null 2>&1 && echo 1 || echo 0` == "1" { "" } else { "sudo" }

# FSDK release parsed from the pinned junction ref — the single source of truth
# for image versioning. e.g. "26.08.0".
export fsdk_version := `grep -oE 'freedesktop-sdk-[0-9]+\.[0-9]+\.[0-9]+' elements/freedesktop-sdk.bst | head -1 | sed 's/freedesktop-sdk-//'`
# Exact junction commit ref (full ref: value), for provenance.
export fsdk_ref := `grep -E '^\s*ref:' elements/freedesktop-sdk.bst | head -1 | sed -E 's/^\s*ref:\s*//'`

# -- BuildStream wrapper ------------------------------------------------------
# Runs any bst command inside the bst2 container via podman.
[group('dev')]
bst *ARGS:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "${HOME}/.cache/buildstream"
    # shellcheck disable=SC2086
    {{sudo_cmd}} podman run --rm \
        --privileged \
        --device /dev/fuse \
        --network=host \
        -v "{{justfile_directory()}}:/src:rw" \
        -v "${HOME}/.cache/buildstream:/root/.cache/buildstream:rw" \
        -w /src \
        "{{bst2_image}}" \
        bash -c 'bst --colors "$@"' -- --no-interactive --error-lines 500 ${BST_FLAGS:-} {{ARGS}}

# Print the FSDK-derived point release used for asset versioning.
[group('info')]
version:
    @echo "{{fsdk_version}}"

# Print the tag set derived from the FSDK release: latest, minor line, point release.
[group('info')]
tags:
    #!/usr/bin/env bash
    set -euo pipefail
    V="{{fsdk_version}}"
    MINOR="$(echo "$V" | cut -d. -f1,2)"
    printf '%s\n%s\n%s\n' latest "$MINOR" "$V"

# -- Validate ------------------------------------------------------
[group('dev')]
validate:
    python3 .github/scripts/check-release-version.py
    just bst show --deps all oci/microraptor-ddi.bst
    just bst show --deps all oci/microraptor-installer.bst

# Run the unit test suite (pytest + bats).
[group('dev')]
test-unit:
    python3 -m pytest tests/unit -q
    bats tests/unit

# -- Build ------------------------------------------------------
[group('build')]
build:
    just export-installer

# -- Export ------------------------------------------------------
[group('installer')]
build-ddi:
    just bst build oci/microraptor-ddi.bst

[group('installer')]
export-ddi: build-ddi
    rm -rf dist/ddi
    mkdir -p dist/ddi
    just bst artifact checkout oci/microraptor-ddi.bst --directory /src/dist/ddi
    @echo "==> wrote DDI payload:" && ls -lh dist/ddi/

[group('installer')]
build-installer:
    just bst build oci/microraptor-installer.bst

[group('build')]
cluster-build REF="main":
    argo submit --from wftmpl/microraptor-build-pipeline \
        --parameter ref={{REF}} \
        --parameter repo=https://github.com/HuntedRaven7/microraptor.git \
        --parameter registry=registry.testing-lab.internal:30500 \
        -n argo \
        --watch

[group('installer')]
export-installer: build-installer
    rm -rf dist/installer-checkout
    mkdir -p dist dist/installer-checkout
    rm -f dist/microraptor-installer-*.raw.zst dist/microraptor-*.efi dist/microraptor-pxe-* dist/SHA256SUMS
    just bst artifact checkout oci/microraptor-installer.bst --directory /src/dist/installer-checkout
    mv dist/installer-checkout/* dist/
    rm -rf dist/installer-checkout
    @echo "==> wrote:" && ls -lh dist/

[group('installer')]
export-pxe: export-installer
    @test -n "$(find dist/ -maxdepth 1 -type f -name 'microraptor-pxe-vmlinuz-*' -print -quit)" || { echo "ERROR: PXE kernel was not exported." >&2; exit 1; }
    @test -n "$(find dist/ -maxdepth 1 -type f -name 'microraptor-pxe-initrd-*.cpio.gz' -print -quit)" || { echo "ERROR: PXE initrd was not exported." >&2; exit 1; }
    @echo "==> wrote PXE artifacts:" && ls -lh dist/microraptor-pxe-*

# Sign exported EFI artifacts for Secure Boot (requires sbsigntool).
# SECUREBOOT_KEY and SECUREBOOT_CERT must point to the private key and certificate files.
# For local use: SECUREBOOT_KEY=/path/to/key.pem SECUREBOOT_CERT=/path/to/cert.pem just sign
[group('installer')]
sign:
    #!/usr/bin/env bash
    set -euo pipefail
    KEY="${SECUREBOOT_KEY:-}"
    CERT="${SECUREBOOT_CERT:-}"
    if [ -z "$KEY" ] || [ -z "$CERT" ]; then
        echo "ERROR: SECUREBOOT_KEY and SECUREBOOT_CERT must be set" >&2
        exit 1
    fi
    if ! command -v sbsign >/dev/null 2>&1; then
        echo "ERROR: sbsign not found. Install sbsigntool." >&2
        exit 1
    fi
    UKI=$(find dist/ -maxdepth 1 -type f -name 'microraptor-*.efi' | head -n1)
    if [ -z "$UKI" ]; then
        echo "ERROR: No UKI found in dist/" >&2
        exit 1
    fi
    echo "==> Signing target UKI: $UKI"
    sbsign --key "$KEY" --cert "$CERT" --output "$UKI" "$UKI"
    echo "==> signed: $UKI"

    IMG=$(find dist/ -maxdepth 1 -type f -name 'microraptor-installer-*.raw.zst' | head -n1)
    if [ -n "$IMG" ]; then
        echo "==> Signing installer UKI in $IMG"
        zstd -d "$IMG" -o /tmp/installer.raw
        LOOP=$(sudo losetup -f --show -P /tmp/installer.raw)
        ESP_PART="${LOOP}p1"
        sudo mkdir -p /tmp/esp
        sudo mount -t vfat "$ESP_PART" /tmp/esp
        sudo sbsign --key "$KEY" --cert "$CERT" --output /tmp/esp/EFI/BOOT/BOOTX64.EFI /tmp/esp/EFI/BOOT/BOOTX64.EFI
        sudo umount /tmp/esp
        sudo losetup -d "$LOOP"
        zstd --rm -T0 -19 -q /tmp/installer.raw -o "$IMG"
        echo "==> signed installer UKI in $IMG"
    fi

# Write the raw GPT installer image to a physical USB drive.
[group('installer')]
flash-installer DEVICE="":
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "{{DEVICE}}" ]; then
        echo "ERROR: Must specify a target block device. Example: just flash-installer /dev/sdX" >&2
        echo "Available writable disk devices:" >&2
        lsblk -p -d -n -o NAME,TYPE,RO,SIZE -b | awk '$2 == "disk" && $3 == "0" && $4 > 0 {printf "  %-15s (%0.1f GB)\n", $1, $4 / 1073741824}' >&2
        exit 1
    fi
    if [ ! -b "{{DEVICE}}" ]; then
        echo "ERROR: {{DEVICE}} is not a valid block device!" >&2
        exit 1
    fi
    IMG=$(find dist/ -type f -name 'microraptor-installer-*.raw.zst' | head -n1)
    if [ -z "${IMG}" ]; then
        echo "ERROR: No exported installer found in dist/." >&2
        echo "Please run: just build-installer && just export-installer" >&2
        exit 1
    fi
    echo "WARNING: All data on {{DEVICE}} will be COMPLETELY DESTROYED!"
    echo "Double-checking device information:"
    lsblk -p "{{DEVICE}}"
    echo
    read -p "Are you absolutely sure you want to write to {{DEVICE}}? [y/N] " -r CONFIRM
    if [[ ! "${CONFIRM}" =~ ^[yY](es)?$ ]]; then
        echo "Aborted."
        exit 1
    fi
    echo "Writing ${IMG} to {{DEVICE}}..."
    sudo sh -c "zstd -dc ${IMG} | dd of={{DEVICE}} bs=4M iflag=fullblock oflag=direct status=progress conv=fsync"
    echo "Successfully flashed the microraptor installer to {{DEVICE}}!"

# Build, install, and reboot the server in QEMU using the raw installer disk.
[group('test')]
show-me-the-future:
    #!/usr/bin/env bash
    set -euo pipefail

    CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
    mkdir -p "$CACHE_DIR"
    WORKDIR="$(mktemp -d "${CACHE_DIR}/microraptor-show-future.XXXXXX")"
    trap 'rm -rf "$WORKDIR"' EXIT

    just build-installer
    just export-installer

    cp dist/microraptor-installer-*.raw.zst "$WORKDIR/installer.raw.zst"
    cp dist/microraptor-pxe-vmlinuz-* "$WORKDIR/installer.vmlinuz"
    cp dist/microraptor-pxe-initrd-*.cpio.gz "$WORKDIR/installer.initrd"
    zstd -d "$WORKDIR/installer.raw.zst" -o "$WORKDIR/installer.raw"
    TARGET_SIZE="${SHOW_ME_THE_FUTURE_DISK_SIZE:-16G}"
    truncate -s "${TARGET_SIZE}" "$WORKDIR/target.raw"

    # Return the first existing file from a list of candidates.
    first_existing() {
      for candidate in "$@"; do
        if [ -f "$candidate" ]; then
          echo "$candidate"
          return 0
        fi
      done
      return 1
    }

    OVMF_CODE=$(first_existing \
      /home/linuxbrew/.linuxbrew/Cellar/qemu/*/share/qemu/edk2-x86_64-code.fd \
      /home/linuxbrew/.linuxbrew/Cellar/qemu/*/share/qemu/edk2-x86_64-secure-code.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.fd \
      /usr/share/OVMF/OVMF_CODE.fd \
      /usr/share/OVMF/OVMF_CODE_4M.fd \
      /usr/share/edk2/x64/OVMF_CODE.4m.fd \
      /usr/share/qemu/edk2-x86_64-code.fd \
      /usr/share/qemu/edk2-x86_64-secure-code.fd \
      /usr/share/qemu/OVMF_CODE.fd) \
      || { echo "ERROR: OVMF_CODE not found"; exit 1; }

    OVMF_VARS=$(first_existing \
      /home/linuxbrew/.linuxbrew/Cellar/qemu/*/share/qemu/edk2-x86_64-vars.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.fd \
      /usr/share/OVMF/OVMF_VARS.fd \
      /usr/share/OVMF/OVMF_VARS_4M.fd \
      /usr/share/edk2/x64/OVMF_VARS.4m.fd \
      /usr/share/qemu/edk2-x86_64-vars.fd \
      /usr/share/qemu/edk2-i386-vars.fd \
      /usr/share/qemu/OVMF_VARS.fd) \
      || true
    if [ -n "$OVMF_VARS" ]; then
      cp "$OVMF_VARS" "$WORKDIR/ovmf-vars.fd"
    else
      truncate -s "$(stat -c '%s' "$OVMF_CODE")" "$WORKDIR/ovmf-vars.fd"
    fi

    echo "==> Booting installer media in QEMU (PXE kernel + initrd)..."
    qemu-system-x86_64 \
        -enable-kvm \
        -m 4096 \
        -cpu host \
        -smp 2 \
        -drive file="$WORKDIR/installer.raw",format=raw,if=virtio,readonly=on \
        -drive file="$WORKDIR/target.raw",format=raw,if=virtio \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$WORKDIR/ovmf-vars.fd" \
        -kernel "$WORKDIR/installer.vmlinuz" \
        -initrd "$WORKDIR/installer.initrd" \
        -append "systemd.unit=system-install.target console=tty0 console=ttyS0,115200 rw unattended" \
        -nographic \
        -serial mon:stdio \
        -no-reboot < /dev/null

    echo "==> Preparing target /var partition..."
    REPART_DIR="$WORKDIR/repart.d"
    mkdir -p "$REPART_DIR"
    printf '%s\n' \
      '[Partition]' \
      'Type=var' \
      'Label=var' \
      'Format=xfs' \
      'GrowFileSystem=yes' \
      > "$REPART_DIR/30-var.conf"

    echo "==> Refreshing target /var partition using systemd-repart..."
    unshare -r systemd-repart \
      --factory-reset=yes \
      --dry-run=no \
      --definitions="$REPART_DIR" \
      "$WORKDIR/target.raw"

    SERIAL_LOG="$WORKDIR/serial.log"
    TARGET_QEMU_PID=""
    cleanup() {
      EXIT_STATUS=$?
      if [ -n "${TARGET_QEMU_PID:-}" ] && kill -0 "$TARGET_QEMU_PID" 2>/dev/null; then
        kill "$TARGET_QEMU_PID" 2>/dev/null || true
        wait "$TARGET_QEMU_PID" 2>/dev/null || true
      fi
      if [ "$EXIT_STATUS" -eq 0 ]; then
        rm -rf "$WORKDIR"
      else
        echo "ERROR: QEMU smoke failed; retaining artifacts at $WORKDIR" >&2
      fi
      exit "$EXIT_STATUS"
    }
    trap cleanup EXIT INT TERM

    echo "==> Booting the installed server in QEMU (background)..."
    qemu-system-x86_64 \
        -enable-kvm \
        -m 4096 \
        -cpu host \
        -smp 2 \
        -drive file="$WORKDIR/target.raw",format=raw,if=virtio \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$WORKDIR/ovmf-vars.fd" \
        -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:8080 \
        -smbios "type=11,value=io.systemd.credential.binary:fstab.extra=L2Rldi9kaXNrL2J5LXBhcnRsYWJlbC92YXIgL3ZhciB4ZnMgZGVmYXVsdHMgMCAwCg==" \
        -smbios "type=11,value=io.systemd.stub.kernel-cmdline-extra=console=tty0 console=ttyS0,,115200 systemd.mask=systemd-firstboot.service" \
        -nographic \
        -serial file:"$SERIAL_LOG" \
        -monitor none &
    TARGET_QEMU_PID=$!

    DEADLINE_SECS="${SHOW_ME_THE_FUTURE_DEADLINE:-${SHOW_ME_THE_FUTURE_TIMEOUT:-600}}"
    START_TIME=$(date +%s)
    echo "==> Polling KubeStellar Console readiness at http://127.0.0.1:8080 (deadline: ${DEADLINE_SECS}s)..."

    while true; do
      if ! kill -0 "$TARGET_QEMU_PID" 2>/dev/null; then
        echo "ERROR: Target QEMU process ($TARGET_QEMU_PID) died unexpectedly!" >&2
        if [ -f "$SERIAL_LOG" ]; then
          echo "==> Serial log tail (last 100 lines):" >&2
          tail -n 100 "$SERIAL_LOG" >&2
        fi
        exit 1
      fi

      HEALTHZ_JSON=$(curl --silent --fail --max-time 2 http://127.0.0.1:8080/healthz 2>/dev/null || true)
      if [ -n "$HEALTHZ_JSON" ] && echo "$HEALTHZ_JSON" | jq -e '.status == "ok"' >/dev/null 2>&1; then
        ROOT_CODE=$(curl --silent --fail --max-time 2 --output /dev/null --write-out "%{http_code}" http://127.0.0.1:8080/ 2>/dev/null || true)
        if [ "$ROOT_CODE" = "200" ]; then
          echo "==> KubeStellar Console is healthy: /healthz status ok, / returned HTTP 200"
          break
        fi
      fi

      NOW=$(date +%s)
      ELAPSED=$((NOW - START_TIME))
      if [ "$ELAPSED" -ge "$DEADLINE_SECS" ]; then
        echo "ERROR: Timed out after ${DEADLINE_SECS}s waiting for KubeStellar Console readiness!" >&2
        if [ -f "$SERIAL_LOG" ]; then
          echo "==> Serial log tail (last 100 lines):" >&2
          tail -n 100 "$SERIAL_LOG" >&2
        fi
        exit 1
      fi

      sleep 2
    done

# Interactively install and boot a persistent local KubeStellar kiosk VM.
[group('test')]
install-vm:
    #!/usr/bin/env bash
    set -euo pipefail

    STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/microraptor/vm-{{fsdk_version}}"
    INSTALLER_RAW="$STATE_DIR/installer.raw"
    TARGET_RAW="$STATE_DIR/target.raw"
    OVMF_VARS="$STATE_DIR/ovmf-vars.fd"
    INSTALL_COMPLETE="$STATE_DIR/installed"
    mkdir -p "$STATE_DIR"

    first_existing() {
      for candidate in "$@"; do
        if [ -f "$candidate" ]; then
          echo "$candidate"
          return 0
        fi
      done
      return 1
    }

    OVMF_CODE=$(first_existing \
      /home/linuxbrew/.linuxbrew/Cellar/qemu/*/share/qemu/edk2-x86_64-code.fd \
      /home/linuxbrew/.linuxbrew/Cellar/qemu/*/share/qemu/edk2-x86_64-secure-code.fd \
      /usr/share/edk2/ovmf/OVMF_CODE.fd \
      /usr/share/OVMF/OVMF_CODE.fd \
      /usr/share/OVMF/OVMF_CODE_4M.fd \
      /usr/share/edk2/x64/OVMF_CODE.4m.fd \
      /usr/share/qemu/edk2-x86_64-code.fd \
      /usr/share/qemu/edk2-x86_64-secure-code.fd \
      /usr/share/qemu/OVMF_CODE.fd) \
      || { echo "ERROR: OVMF_CODE not found"; exit 1; }

    if [ ! -f "$OVMF_VARS" ]; then
      OVMF_TEMPLATE=$(first_existing \
        /home/linuxbrew/.linuxbrew/Cellar/qemu/*/share/qemu/edk2-x86_64-vars.fd \
        /usr/share/edk2/ovmf/OVMF_VARS.fd \
        /usr/share/OVMF/OVMF_VARS.fd \
        /usr/share/OVMF/OVMF_VARS_4M.fd \
        /usr/share/edk2/x64/OVMF_VARS.4m.fd \
        /usr/share/qemu/edk2-x86_64-vars.fd \
        /usr/share/qemu/edk2-i386-vars.fd \
        /usr/share/qemu/OVMF_VARS.fd) \
        || { echo "ERROR: OVMF_VARS not found"; exit 1; }
      cp "$OVMF_TEMPLATE" "$OVMF_VARS"
    fi

    if [ ! -f "$INSTALL_COMPLETE" ]; then
      just export-installer
      INSTALLER_ARCHIVE=$(find dist/ -maxdepth 1 -type f -name 'microraptor-installer-*.raw.zst' -print -quit)
      [ -n "$INSTALLER_ARCHIVE" ] || { echo "ERROR: No exported installer found in dist/." >&2; exit 1; }
      zstd --decompress --force "$INSTALLER_ARCHIVE" --output "$INSTALLER_RAW"
      truncate -s "${INSTALL_VM_DISK_SIZE:-16G}" "$TARGET_RAW"

      echo "==> Booting the interactive installer in QEMU..."
      qemu-system-x86_64 \
        -enable-kvm \
        -m 4096 \
        -cpu host \
        -smp 2 \
        -drive file="$INSTALLER_RAW",format=raw,if=virtio,readonly=on \
        -drive file="$TARGET_RAW",format=raw,if=virtio \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$OVMF_VARS"
      touch "$INSTALL_COMPLETE"
    fi

    echo "==> Booting the installed kiosk..."
    qemu-system-x86_64 \
      -enable-kvm \
      -m 4096 \
      -cpu host \
      -smp 2 \
      -drive file="$TARGET_RAW",format=raw,if=virtio \
      -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
      -drive if=pflash,format=raw,file="$OVMF_VARS" \
      -nic user,model=virtio-net-pci,hostfwd=tcp:127.0.0.1:8080-:8080 &
    QEMU_PID=$!
    cleanup() {
      if kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID"
        wait "$QEMU_PID" || true
      fi
    }
    trap cleanup EXIT INT TERM

    until curl --silent --show-error --max-time 2 --output /dev/null http://127.0.0.1:8080/; do
      if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        wait "$QEMU_PID"
        exit 1
      fi
      sleep 2
    done

    xdg-open http://127.0.0.1:8080/
    wait "$QEMU_PID"
    trap - EXIT INT TERM
