#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Homelab server: networking, WiFi and SSH
#
# What the image needs in order to function. The workstation's counterpart is
# 25-hardware-and-session.sh, and the WiFi half of this is deliberately the same
# package set in the same order: a node in a homelab is a box on a shelf that
# someone has to reach over wifi, and the reason Intel cards associate but never
# connect is the same reason it is true on a desktop.
#
# What is different from the workstation phase, and why it is a separate script
# rather than a conditional:
#
#   sshd           added. A cluster is administered over the network.
#   session plumbing  dropped. polkit agents, xdg-user-dirs and the rest of
#                    25-hardware-and-session.sh's "session" group are desktop
#                    session machinery with no session here to serve.
#   laptop power   dropped. TLP/fstrim tuning exists to keep a machine that runs
#                    on battery; a server has no battery.
#
# WiFi on a server is worth a sentence, because it is usually assumed to be a
# mistake. It is not: a homelab node is frequently a laptop or a mini PC in a
# room where ethernet is not, and the alternative to wifi on a node nobody has
# physical access to is a node that cannot be fixed at all.
###############################################################################

# dnf5_retry, and with it the DNF5_RETRY_ATTEMPTS default, which lives in this
# helper rather than in copr-helpers.sh. Sourced explicitly because this phase
# installs from Fedora proper and needs no COPR: it does not need
# copr-helpers.sh, and reaching for it just to pick up a default would have
# hidden that. It reached for nothing, and the first transaction in the image
# failed on an unbound variable.
#
# shellcheck source=/dev/null
source /ctx/build/dnf5-retry.sh

# Enable nullglob for all glob operations to prevent failures on empty matches
shopt -s nullglob

echo "::group:: Install the WiFi stack"

# Identical to the workstation phase, and for the identical reasons:
# NetworkManager-wifi is the plugin that lets NetworkManager see wireless at all,
# wpa_supplicant is the supplicant it drives (iwd is the alternative and buys
# nothing here), and iw is the diagnostic for when an adapter will not associate.
#
# 5 packages, 8 MB. Everything expensive about WiFi is the firmware below.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
  NetworkManager-wifi \
  wpa_supplicant \
  iw

echo "::endgroup::"

echo "::group:: Install the Intel WiFi firmware"

# The part that surprises people, and it surprises them identically on a server.
# The base already carries linux-firmware, which holds the licence file for iwlwifi
# and none of the actual blobs. Without these packages a machine with an Intel
# card sees the adapter in hardware and never associates -- and on a headless node
# that symptom has no keyboard in front of it.
#
# All three, because which applies depends on the card and the failure is total:
#
#   iwlwifi-mvm-firmware   98 MB  modern Intel: AX200/AX210/AX300, BE, 6E
#   iwlwifi-mld-firmware   35 MB  the MLD variants of the above (AX210+, BE200)
#   iwlwifi-dvm-firmware   14 MB  legacy cards predating the mvm driver
#
# Realtek is 7 MB and MediaTek 5 MB if this runs on one; Broadcom wants
# brcmfmac-firmware (10 MB). Adding one is a line, not a redesign.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
  iwlwifi-mvm-firmware \
  iwlwifi-mld-firmware \
  iwlwifi-dvm-firmware

echo "::endgroup::"

echo "::group:: Install sshd and the base network stack"

# openssh-server is the point of this group. Everything else is what a node needs
# to be useful once it is reachable.
#
# NetworkManager and NetworkManager-wifi come from Fedora proper. NetworkManager
# is here rather than relying on systemd-networkd because the WiFi stack above
# is NetworkManager's, and a system running both is a system where which one owns
# an interface is decided by timing.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
  openssh-server \
  NetworkManager \
  NetworkManager-wifi \
  openssh-clients

echo "::endgroup::"

echo "::group:: Configure sshd"

# Three settings, each of which is a deliberate narrowing of Fedora's default.
#
# PasswordAuthentication=no
#   Key-only. A node reachable over the open internet with password auth is a
#   node being password-guessing, and fail2ban exists to slow that down rather
#   than to stop it. With keys only, the brute force has nothing to succeed at.
#   This also means the first-boot enable of sshd is useless until a key is
#   installed, which is the correct order of operations: the node is unreachable
#   until someone has configured it.
#
# PermitRootLogin prohibit-password
#   Root may log in with a key, not with a password. Not "no": on a cluster,
#   root is how node-level recovery happens when a kubelet config is wrong, and
#   forbidding it entirely turns a recoverable problem into a rebuild.
#
# X11Forwarding no
#   There is no X server on a node, so forwarding is dead configuration.
printf '%s\n' \
  '# Managed by this image. See build/25-server-network.sh for why each is narrowed.' \
  'PasswordAuthentication no' \
  'PermitRootLogin prohibit-password' \
  'X11Forwarding no' \
  >/etc/ssh/sshd_config.d/10-microraptor-homelab.conf

# The include is the mechanism, and it is checked rather than assumed: openssh on
# Fedora ships the drop-in directory and the Include line for it in the main
# config, but a base that did not would silently ignore every setting above, and
# key-only sshd is not something to discover from a breach.
if ! grep -qE '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config\.d/\*\.conf' \
  /etc/ssh/sshd_config; then
  echo "::error::sshd_config has no Include for /etc/ssh/sshd_config.d/*.conf;" >&2
  echo "::error::the hardening above would be silently ignored" >&2
  exit 1
fi

echo "::endgroup::"

echo "::group:: Enable the network services"

# NetworkManager, so a node gets an address and a route without anyone running
# nmcli on a headless box.
systemctl enable NetworkManager.service

# Enabled, unlike tailscaled in 20-server-base.sh and for the same distinction:
# sshd reads its host keys and starts, fully functional, with no per-machine
# input. There is no auth key, licence, or download in the way.
systemctl enable sshd.service

echo "::endgroup::"

# Restore default glob behavior
shopt -u nullglob