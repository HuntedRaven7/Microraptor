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
        bash -c 'bst --colors "$@"' -- --no-interactive ${BST_FLAGS:-} {{ARGS}}

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
    python3 .github/scripts/check-k0s-version.py
    just bst show --deps all oci/microraptor-ddi.bst
    just bst show --deps all oci/microraptor-installer.bst
    just bst show --deps all oci/k0s-sysext.bst

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

# -- k0s systemd-sysext -------------------------------------------------------
[group('sysext')]
build-sysext:
    just bst build oci/k0s-sysext.bst

[group('sysext')]
export-sysext: build-sysext
    rm -rf dist/sysext dist/sysext-checkout
    mkdir -p dist/sysext-checkout dist/sysext
    just bst artifact checkout oci/k0s-sysext.bst --directory /src/dist/sysext-checkout
    cp dist/sysext-checkout/k0s-*.raw.zst dist/sysext/
    cp dist/sysext-checkout/SHA256SUMS dist/sysext/
    rm -rf dist/sysext-checkout
    for f in dist/sysext/k0s-*.raw.zst; do [ -f "$f" ] && ln -sf "$(basename "$f")" "dist/sysext/k3s-${f#*dist/sysext/k0s-}"; done
    @echo "==> wrote k0s sysext:" && ls -lh dist/sysext/

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
      /usr/share/qemu/OVMF_CODE.fd) \
      || { echo "ERROR: OVMF_CODE not found"; exit 1; }

    OVMF_VARS=$(first_existing \
      /home/linuxbrew/.linuxbrew/Cellar/qemu/*/share/qemu/edk2-x86_64-vars.fd \
      /usr/share/edk2/ovmf/OVMF_VARS.fd \
      /usr/share/OVMF/OVMF_VARS.fd \
      /usr/share/OVMF/OVMF_VARS_4M.fd \
      /usr/share/edk2/x64/OVMF_VARS.4m.fd \
      /usr/share/qemu/OVMF_VARS.fd) \
      || true
    if [ -n "$OVMF_VARS" ]; then
      cp "$OVMF_VARS" "$WORKDIR/ovmf-vars.fd"
    else
      truncate -s "$(stat -c '%s' "$OVMF_CODE")" "$WORKDIR/ovmf-vars.fd"
    fi

    echo "==> Booting installer media in QEMU..."
    qemu-system-x86_64 \
        -enable-kvm \
        -m 4096 \
        -cpu host \
        -smp 2 \
        -drive file="$WORKDIR/installer.raw",format=raw,if=virtio,readonly=on \
        -drive file="$WORKDIR/target.raw",format=raw,if=virtio \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$WORKDIR/ovmf-vars.fd" \
        -nographic \
        -serial mon:stdio \
        -no-reboot < /dev/null

    echo "==> Rebooting into the installed server..."
    qemu-system-x86_64 \
        -enable-kvm \
        -m 4096 \
        -cpu host \
        -smp 2 \
        -drive file="$WORKDIR/target.raw",format=raw,if=virtio \
        -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
        -drive if=pflash,format=raw,file="$WORKDIR/ovmf-vars.fd" \
        -nographic \
        -serial mon:stdio
