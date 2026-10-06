#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Homelab server: base packages and hardening
#
# What the image is, as opposed to what it needs in order to function. The
# workstation's counterpart is 20-packages-and-services.sh; this one exists
# because a server's answer to "what does this image is" has no desktop in it,
# so sharing one phase would put a compositor and a display manager behind a
# conditional.
#
# The deliberate omissions, since they are the whole difference from the
# workstation phase and each one is a decision rather than an oversight:
#
#   gdm / ly          no display manager. There is no VT login here; the cluster
#                     is reached over the network, and a login screen on a node
#                     nobody logs into is an attack surface with no user.
#   ghostty, mangowm  no compositor and no terminal. A node runs services.
#   voxtype           dictation. Not a server concern.
#   uupd              the workstation's update policy. See the note below -- this
#                     phase installs it but does not enable it, which is the one
#                     place the two images disagree on purpose.
#
# What it does install is the server's actual baseline: the toolchain, the
# security layer, and the thing that makes a cluster of these reachable.
###############################################################################

# Source helper functions
# shellcheck source=/dev/null
source /ctx/build/copr-helpers.sh

# Enable nullglob for all glob operations to prevent failures on empty matches
shopt -s nullglob

echo "::group:: Install the server baseline"

# just/fzf/jq are the same three the workstation ships, for the same reasons: ujust
# recipes and the ublue setup hooks consume them, and fzf keeps `ujust --choose`
# from downloading Homebrew on first use.
#
# The rest is a server's floor rather than a wish list:
#
#   vim                an operator on a node with no network needs an editor that
#                      is already there. Nothing here is installed from a
#                      repository that can be closed afterwards.
#   git, git-core      cluster bring-up is cloning things.
#   rsync              how files get onto nodes, and what 10-overlay.sh uses.
#   curl               fetching things, and the diagnostic when a node cannot
#                      resolve anything.
#   chrony             time sync. A Kubernetes node whose clock drifts breaks TLS
#                      between components, and the failure looks like a network
#                      problem rather than a clock one.
#   iproute, iputils   "is this node on the network", which is the first question
#                      in every incident.
#   firewalld          the host firewall fail2ban bans through. Named here because
#                      fail2ban without it bans nothing -- see the group below.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
  just \
  fzf \
  jq \
  vim \
  git \
  git-core \
  rsync \
  curl \
  chrony \
  iproute \
  iputils \
  firewalld

echo "::endgroup::"

echo "::group:: Install Tailscale"

# Fedora 44 proper -- no third-party repository. The 30-tailscale.sh.example in
# build/ does it the other way for a workstation, adding tailscale.repo so the
# package tracks Tailscale's own releases; that is a better answer for a machine
# whose operator wants the newest client, and a worse one here, because that
# repository is then live on every node in the cluster and is not something
# 90-cleanup.sh closes (it only closes the file if a phase enabled it).
#
# What tailscale is for in this image: the nodes get MagicDNS names instead of
# IP addresses, so a cluster member that reboots onto a new DHCP lease is still
# reachable under the same name. That is the difference between a cluster you can
# rebase and one you have to rediscover by hand.
#
# Not enabled. `tailscaled` starts and sits there holding no auth key, so
# enabling it at build time ships a daemon that cannot do anything until a person
# runs `tailscale up`. The README carries that step. `tailscaled.service` is
# socket-activated, so the enable is all that is needed once there is a key.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y tailscale

echo "::endgroup::"

echo "::group:: Install and configure fail2ban"

# fail2ban 1.1.0 is in Fedora 44 proper.
#
# Enabled, which is the opposite decision from tailscaled and for a reason that
# is not a matter of taste: fail2ban.service starts, reads its jail
# configuration, and is fully functional with no user input at all. It watches
# the logs for patterns that already exist. There is nothing to download and
# nothing to click, so there is no "not ready" state to wait for.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y fail2ban

# Two files, and the split between them matters.
#
# jail.d/ holds configuration the operator is expected to change. It is marked
# .local so fail2ban's own defaults can never overwrite it on upgrade, and it is
# shipped enabled.
#
# fail2ban.d/ is what upstream warns about: files there are managed by the
# package and get replaced. Nothing is written there.
install -d -m0755 /etc/fail2ban/jail.d

# sshd is the only jail that is meaningful on a node whose entire job is to be
# reachable over the network, so it is the only one enabled. enabled=true is
# needed explicitly: fail2ban ships with sshd present but disabled, because it
# cannot know what else is listening.
#
# The three settings, and why each is not the fail2ban default:
#
#   bantime  10m    The upstream default is 10 minutes too, but fail2ban's
#                   *incremental* mode would then keep extending it for a
#                   persistent offender, which is the behaviour people hit and
#                   misread as "my ban never expires". bantime is stated anyway
#                   so the intent is visible rather than inherited.
#   findtime 10m    Window in which failures are counted.
#   maxretry 5      Attempts allowed in that window. Five is the value
#                   fail2ban's own documentation settles on and it is what
#                   fail2ban's shipped sshd jail shipped with before it was
#                   disabled; anything stricter starts banning people who fat-
#                   finger a password.
cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
# Managed by this image. Local overrides, not the fail2ban.d/ replacement zone.
[sshd]
enabled  = true
bantime  = 10m
findtime = 10m
maxretry = 5
EOF

echo "::endgroup::"

echo "::group:: Enable the server services"

# firewalld has to be enabled for fail2ban's bans to have any effect. fail2ban
# writes a drop-in into /etc/firewalld/direct.d/, and firewalld is what reads it;
# with firewalld stopped that file is inert and fail2ban bans nothing while
# appearing to work. That is the single most common way a fail2ban install ends
# up decorative.
systemctl enable firewalld.service

# chrony, for the reason in the baseline group above.
systemctl enable chronyd.service

# uupd is installed but NOT enabled here, and this is the one unit in the whole
# phase where the workstation image and this one deliberately disagree.
#
# The workstation enables it because a desktop should update itself on a
# schedule. This image does not: every node in the cluster runs the same update
# policy at the same time, and uupd applies a pending update and reboots. A
# three-node cluster that reboots itself in unison loses quorum. Rolling a
# cluster means updating nodes one at a time, deliberately, by an operator.
#
# So the daemon is present (a node can be opted in with
# `systemctl enable uupd.timer` when that operator wants it) and the timer is
# not. Leaving uupd's config in place is what makes opting in a one-liner
# instead of a reinstall.

echo "::endgroup::"

echo "::group:: Finalise the Utah package factory"

# Closed here for the same reason 20-packages-and-services.sh closes it: the
# factory's file:///etc/utah-packages baseurl only exists while the bind mount
# does, and 90-cleanup.sh closes it too. Both, because a live repository whose
# baseurl is a path that will not resolve is exactly the thing that makes every
# later dnf5 call noisy.
#
# utah.repo arrives enabled=1 because that is how the Containerfile leaves it.
# This phase is the last thing in this image's build that runs dnf5, so this is
# the last point at which it can be closed without leaving a window.
#
# Guarded, because the file is copied in by the Containerfile and must be there,
# and failing the build when it is not beats shipping a live repository.
if [[ -f /etc/yum.repos.d/utah.repo ]]; then
  sed -i 's/^enabled=1$/enabled=0/' /etc/yum.repos.d/utah.repo
  if grep -qE '^enabled=1' /etc/yum.repos.d/utah.repo; then
    echo "::error::utah-packages is still enabled in /etc/yum.repos.d/utah.repo" >&2
    exit 1
  fi
  echo "utah-packages: enabled=0 (the factory mount does not survive this phase)"
else
  echo "::error::/etc/yum.repos.d/utah.repo is missing; cannot close the package factory" >&2
  exit 1
fi

echo "::endgroup::"

# Restore default glob behavior
shopt -u nullglob