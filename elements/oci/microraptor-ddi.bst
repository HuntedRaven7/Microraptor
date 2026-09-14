kind: script
description: |
  Produce the microraptor OS DDI payload filesystem image.

  Output: microraptor-ddi-<ver>.raw.zst + SHA256SUMS

  The output .raw is a filesystem image consumed by installer repart config:
  files/installer/repart.d/20-root-a.conf via CopyBlocks=.

build-depends:
  - base/base-stack.bst
  - freedesktop-sdk.bst:components/xfsprogs.bst
  - freedesktop-sdk.bst:components/findutils.bst
  - freedesktop-sdk.bst:components/kmod.bst
  - freedesktop-sdk.bst:components/zstd.bst
  - freedesktop-sdk.bst:components/openssh.bst
  - freedesktop-sdk.bst:components/systemd-libs.bst
  - filename: microraptor/os-rootfs.bst
    config:
      location: /layer

variables:
  ddi-version: "%{release-version}"

config:
  commands:
    - |
      set -euo pipefail
      OUT="%{install-root}"
      FNAME="microraptor-ddi-%{ddi-version}.raw"

      rm -rf /layer/usr/lib/debug
      find /layer -type f -name '*.debug' -delete
      find /layer -type f -name '*.a' -delete

      KVER="$(basename "$(find /layer/usr/lib/modules -mindepth 1 -maxdepth 1 -type d | head -n1)")"
      if [ -z "${KVER}" ]; then
        echo "ERROR: no target kernel module tree found under /layer/usr/lib/modules" >&2
        exit 1
      fi
      rm -f "/layer/usr/lib/modules/${KVER}/vmlinux" "/layer/usr/lib/modules/${KVER}/System.map"
      depmod -b /layer "${KVER}"

      # Copy systemd and TPM2 shared libraries from multiarch path to standard
      # /usr/lib (no ld.so.conf entry covers the multiarch dir, so dlopen of
      # libtss2 by systemd-creds would otherwise fail and force the plaintext
      # credential fallback). This must happen BEFORE mkfs.xfs -p /layer so the
      # libraries are included in the image.
      echo "=== Copying systemd + TPM2 shared libraries to /usr/lib ==="
      for lib in /layer/usr/lib/x86_64-linux-gnu/libsystemd-*.so* /layer/usr/lib/x86_64-linux-gnu/libudev-*.so* /layer/usr/lib/x86_64-linux-gnu/systemd/libsystemd-*.so* /layer/usr/lib/x86_64-linux-gnu/libtss2-*.so*; do
        if [ -f "${lib}" ]; then
          cp -av "${lib}" /layer/usr/lib/
          echo "Copied: ${lib}"
        fi
      done
      echo "=== Done copying systemd + TPM2 shared libraries ==="

      # Verify critical systemd files exist before creating image
      echo "=== Verifying DDI contents ==="
      echo "Checking /layer/usr/lib/systemd/systemd:"
      ls -la /layer/usr/lib/systemd/systemd 2>&1 || true
      echo "Checking systemd shared libraries:"
      ls -la /layer/usr/lib/libsystemd-*.so* 2>&1 || true
      echo "Checking libtss2 libraries for systemd-creds TPM2 support:"
      ls -la /layer/usr/lib/libtss2-*.so* 2>&1 || true
      echo "Checking if systemd binary runs (using target dynamic linker):"
      LD_LIBRARY_PATH=/layer/usr/lib /layer/usr/lib/systemd/systemd --version >/dev/null 2>&1 && echo "SUCCESS: systemd binary runs" || (echo "FAILURE: systemd binary failed to run"; ldd /layer/usr/lib/systemd/systemd 2>&1 | grep -E "not found|=>" || true; exit 1)
      echo "=== Verification complete ==="

      # Stage extracted CA certificate bundle into target DDI rootfs
      mkdir -p /layer/etc/pki/ca-trust/extracted /layer/etc/ssl/certs /layer/etc/pki/tls/certs
      cp -a /etc/pki/ca-trust/extracted/* /layer/etc/pki/ca-trust/extracted/
      ln -sf /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /layer/etc/ssl/certs/ca-certificates.crt
      ln -sf /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /layer/etc/pki/tls/certs/ca-bundle.crt
      ln -sf /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem /layer/etc/pki/tls/cert.pem

      # Mask systemd-firstboot to prevent interactive prompts on headless first boot
      mkdir -p /layer/etc/systemd/system
      ln -sf /dev/null /layer/etc/systemd/system/systemd-firstboot.service

      # Enable auditd with minimal ruleset for security compliance
      mkdir -p /layer/etc/audit/rules.d
      printf '%s\n' \
        '-w /etc/passwd -p wa -k identity' \
        '-w /etc/group -p wa -k identity' \
        '-w /etc/shadow -p wa -k identity' \
        '-w /etc/sudoers -p wa -k actions' \
        '-w /etc/sudoers.d/ -p wa -k actions' \
        '-w /var/log/auth.log -p wa -k auth' \
        '-w /etc/ssh/sshd_config -p wa -k sshd' \
        '-a always,exit -F arch=b64 -S execve -k exec' \
        > /layer/etc/audit/rules.d/50-microraptor.rules
      chmod 0640 /layer/etc/audit/rules.d/50-microraptor.rules
      mkdir -p /layer/etc/systemd/system/multi-user.target.wants
      ln -sf /usr/lib/systemd/system/auditd.service \
        /layer/etc/systemd/system/multi-user.target.wants/auditd.service

      # Ensure standard /etc/hosts exists for container runtimes
      printf '127.0.0.1   localhost\n::1         localhost ip6-localhost ip6-loopback\n' > /layer/etc/hosts

      # Prevent screen from turning off when laptop lid closes
      mkdir -p /layer/etc/systemd/logind.conf.d
      printf '[Login]\nHandleLidSwitch=ignore\nHandleLidSwitchExternalPower=ignore\n' > /layer/etc/systemd/logind.conf.d/noclose.conf

      # Mount /var from its own partition when present. systemd-sysinstall
      # skips creating /var (deferPartitionsFactoryReset=true), so a missing
      # partition must degrade gracefully instead of dropping into emergency.
      printf '/dev/disk/by-partlabel/var /var xfs defaults,nofail,x-systemd.device-timeout=10 0 0\n' > /layer/etc/fstab

      # Ensure all standard virtual, serial, and hypervisor consoles allow root login
      printf 'tty0\ntty1\ntty2\ntty3\ntty4\ntty5\ntty6\nttyS0\nttyS1\nconsole\nhvc0\n' > /layer/etc/securetty

      # Accounts are owned by systemd-sysusers at first boot, so passwd/shadow
      # are created with the root password hash from the provisioned credential
      # store instead of being pre-seeded locked. Remove the extra-fs /etc
      # scaffolds, otherwise a pre-existing root entry suppresses the
      # passwd.hashed-password.root credential when sysusers runs.
      rm -f /layer/etc/passwd /layer/etc/group /layer/etc/shadow
      # systemd-sysusers.service is gated on ConditionNeedsUpdate=|/etc (skipped
      # when /etc/.updated is newer than /usr) and ConditionFirstBoot-dependent
      # credential provisioning needs no pre-existing machine-id. Stale stamps
      # from the base layers would silently skip user creation and brick console
      # login, so strip them: the always-run drop-in below makes sysusers run
      # regardless, and systemd regenerates both stamps/ids on first boot.
      rm -f /layer/etc/.updated /layer/etc/machine-id /layer/etc/.pwd.lock

      # Run systemd-sysusers on first boot to create root/core and all system
      # users, and the credential provisioning service that feeds sysusers the
      # root password (TPM2-sealed when available).
      mkdir -p /layer/usr/lib/systemd/system/sysinit.target.wants
      ln -sf /usr/lib/systemd/system/systemd-sysusers.service \
        /layer/usr/lib/systemd/system/sysinit.target.wants/systemd-sysusers.service
      ln -sf /usr/lib/systemd/system/microraptor-cred-provision.service \
        /layer/usr/lib/systemd/system/sysinit.target.wants/microraptor-cred-provision.service

      # Console login on the active VT. The 90-systemd.preset enable getty@.service
      # is never applied in this image-first flow (systemd-firstboot is masked and
      # nothing runs preset-all), so without an explicit symlink no getty instance
      # is pulled into getty.target and the boot finishes with no login prompt.
      mkdir -p /layer/usr/lib/systemd/system/getty.target.wants
      ln -sf /usr/lib/systemd/system/getty@.service \
        /layer/usr/lib/systemd/system/getty.target.wants/getty@tty1.service

      # Same preset problem for networking and SSH: the 90-systemd.preset
      # (systemd-networkd, systemd-resolved) and zz-enable-sshd.preset enables
      # never fire, so without explicit symlinks the installed OS has no
      # network and no sshd. Wire them into multi-user.target explicitly.
      ln -sf /usr/lib/systemd/system/systemd-networkd.service \
        /layer/etc/systemd/system/multi-user.target.wants/systemd-networkd.service
      ln -sf /usr/lib/systemd/system/systemd-resolved.service \
        /layer/etc/systemd/system/multi-user.target.wants/systemd-resolved.service
      ln -sf /usr/lib/systemd/system/sshd.service \
        /layer/etc/systemd/system/multi-user.target.wants/sshd.service

      # DHCP on all ethernet interfaces (systemd ships no default that
      # matches physical NICs, so without this networkd stays silent).
      mkdir -p /layer/etc/systemd/network
      printf '[Match]\nName=en* eth* ens* enp*\n\n[Network]\nDHCP=yes\n' \
        > /layer/etc/systemd/network/80-dhcp.network

      # run0-based privilege escalation: wheel group gets passwordless polkit access
      mkdir -p /layer/etc/polkit-1/rules.d
      printf '%s\n' \
        'polkit.addRule(function(action, subject) {' \
        '  if (subject.isInGroup("wheel")) {' \
        '    return polkit.Result.YES;' \
        '  }' \
        '});' \
        > /layer/etc/polkit-1/rules.d/50-core-wheel.rules
      chmod 0644 /layer/etc/polkit-1/rules.d/50-core-wheel.rules

      # Basic nftables firewall: allow SSH, DHCP, outbound traffic; drop everything else
      mkdir -p /layer/etc/nftables.d
      printf '%s\n' \
        'flush ruleset' \
        '' \
        'table inet filter {' \
        '  chain input {' \
        '    type filter hook input priority 0; policy drop;' \
        '    ct state established,related accept' \
        '    iif lo accept' \
        '    icmp type echo-request accept' \
        '    tcp dport 22 accept' \
        '    udp dport 67 accept' \
        '    udp dport 68 accept' \
        '    drop' \
        '  }' \
        '  chain forward {' \
        '    type filter hook forward priority 0; policy drop;' \
        '    drop' \
        '  }' \
        '  chain output {' \
        '    type filter hook output priority 0; policy accept;' \
        '  }' \
        '}' \
        > /layer/etc/nftables.conf
      chmod 0644 /layer/etc/nftables.conf

      mkdir -p /layer/etc/systemd/system/multi-user.target.wants
      ln -sf /usr/lib/systemd/system/nftables.service \
        /layer/etc/systemd/system/multi-user.target.wants/nftables.service

      # FSDK ships no nftables.service unit, so the symlink above would dangle
      # and the firewall would never load. Ship the unit ourselves (stock
      # Fedora shape): sysusers -> nftables -> network-pre -> networkd is
      # acyclic, and default dependencies keep it out of early sysinit.
      mkdir -p /layer/usr/lib/systemd/system
      printf '%s\n' \
        '[Unit]' \
        'Description=Load Microraptor nftables firewall' \
        'Documentation=man:nft(8)' \
        'Wants=network-pre.target' \
        'Before=network-pre.target' \
        'After=systemd-sysusers.service' \
        '' \
        '[Service]' \
        'Type=oneshot' \
        'RemainAfterExit=yes' \
        'ExecStart=/usr/bin/nft --file /etc/nftables.conf' \
        'ExecReload=/usr/bin/nft --file /etc/nftables.conf' \
        'ExecStop=/usr/bin/nft flush ruleset' \
        '' \
        '[Install]' \
        'WantedBy=multi-user.target' \
        > /layer/usr/lib/systemd/system/nftables.service
      chmod 0644 /layer/usr/lib/systemd/system/nftables.service

      # Build stamp on the console banner: a photo of the login screen then
      # identifies exactly which build is running, with no shell access needed.
      mkdir -p /layer/etc/issue.d
      printf 'Build %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > /layer/etc/issue.d/90-build.issue

      # Kernel hardening sysctl settings
      mkdir -p /layer/etc/sysctl.d
      printf '%s\n' \
        'net.ipv4.ip_forward=0' \
        'net.ipv4.conf.all.send_redirects=0' \
        'net.ipv4.conf.default.send_redirects=0' \
        'net.ipv4.conf.all.accept_redirects=0' \
        'net.ipv4.conf.default.accept_redirects=0' \
        'net.ipv6.conf.all.accept_redirects=0' \
        'net.ipv6.conf.default.accept_redirects=0' \
        'net.ipv4.conf.all.secure_redirects=0' \
        'net.ipv4.conf.all.log_martians=1' \
        'net.ipv4.tcp_syncookies=1' \
        'net.ipv4.tcp_rfc1337=1' \
        'net.ipv4.conf.all.rp_filter=1' \
        'kernel.dmesg_restrict=1' \
        'kernel.kptr_restrict=2' \
        'kernel.perf_event_paranoid=3' \
        'kernel.yama.ptrace_scope=2' \
        'fs.protected_symlinks=1' \
        'fs.protected_hardlinks=1' \
        'fs.protected_fifos=2' \
        'fs.protected_regular=2' \
        > /layer/etc/sysctl.d/99-microraptor-hardening.conf
      chmod 0644 /layer/etc/sysctl.d/99-microraptor-hardening.conf

      mkdir -p /layer/home/core
      chmod 0755 /layer/home/core

      # Pre-generate SSH host keys for first boot remote diagnostics
      mkdir -p /layer/etc/ssh
      ssh-keygen -q -N "" -t ed25519 -f /layer/etc/ssh/ssh_host_ed25519_key
      ssh-keygen -q -N "" -t rsa -b 3072 -f /layer/etc/ssh/ssh_host_rsa_key
      chmod 0600 /layer/etc/ssh/ssh_host_*_key
      chmod 0644 /layer/etc/ssh/ssh_host_*.pub

      # Sum actual file sizes across bind mounts (du -sb reports content bytes, not overlay blocks).
      ROOT_BYTES=$(du -sb /layer | cut -f1)
      echo "Computed root filesystem size: ${ROOT_BYTES} bytes"

      # 25% overhead and 100MB margin for XFS metadata, journal, and structures.
      TARGET_BYTES=$(( ROOT_BYTES + ROOT_BYTES / 4 + 100 * 1024 * 1024 ))

      # Align TARGET_BYTES to 4096-byte boundary (multiple of 512/4096) for sector compatibility
      TARGET_BYTES=$(( (TARGET_BYTES + 4095) / 4096 * 4096 ))

      # Pre-allocate the raw file to the exact target size.
      truncate -s "${TARGET_BYTES}" "${OUT}/${FNAME}"

      echo "Allocating XFS image of ${TARGET_BYTES} bytes"
      mkfs.xfs -f -L microraptor -p /layer "${OUT}/${FNAME}"

      zstd --rm -T0 -19 -q "${OUT}/${FNAME}" -o "${OUT}/${FNAME}.zst"
      (
        cd "${OUT}"
        sha256sum --binary "${FNAME}.zst" > SHA256SUMS
      )