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

      # Ensure persistent /var is mounted from its partition label
      printf '/dev/disk/by-partlabel/var /var xfs defaults 0 0\n' > /layer/etc/fstab

      # Ensure all standard virtual, serial, and hypervisor consoles allow root login
      printf 'tty0\ntty1\ntty2\ntty3\ntty4\ntty5\ntty6\nttyS0\nttyS1\nconsole\nhvc0\n' > /layer/etc/securetty

      # Seed locked root account - use 'run0 -u root /bin/sh' for root shell
      mkdir -p /layer/etc
      printf 'root:!:19700:0:99999:7:::\n' > /layer/etc/shadow
      chmod 0600 /layer/etc/shadow
      printf 'core:!:19700:0:99999:7:::\n' >> /layer/etc/shadow
      printf 'root:x:0:0:root:/root:/bin/sh\n' > /layer/etc/passwd
      chmod 0644 /layer/etc/passwd
      printf 'core:x:1000:1000:core:/home/core:/bin/sh\n' >> /layer/etc/passwd
      printf 'root:x:0:\n' > /layer/etc/group
      chmod 0644 /layer/etc/group
      printf 'core:x:1000:\n' >> /layer/etc/group
      printf 'wheel:x:998:\n' >> /layer/etc/group

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
