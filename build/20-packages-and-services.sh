#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Desktop packages
#
# This phase owns RPM and COPR installation. Packages are installed here, never
# in 10-overlay.sh, so a filesystem-overlay change cannot invalidate the
# expensive package layer above it.
#
# The default set keeps the reference image functional on first boot:
#   just  - the ujust entry point; base Fedora ships no just binary
#   gum   - interactive prompts used by the shared and custom ujust recipes
#   fzf   - ujust --choose, without a first-use Homebrew download
#   jq    - the ublue setup hooks and several recipes
#   uupd  - background update policy, from the ublue-os/packages COPR
#
# dnf5-plugins, rsync and flatpak are installed by the Containerfile's package
# sources phase rather than here, because the overlay and cleanup phases both
# need them and they run before this one.
###############################################################################

# Source helper functions
# shellcheck source=/dev/null
source /ctx/build/copr-helpers.sh

# Enable nullglob for all glob operations to prevent failures on empty matches
shopt -s nullglob

echo "::group:: Install Default Packages"

dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y just gum fzf jq

echo "::endgroup::"

echo "::group:: Install uupd"

# uupd owns the update policy. Its binary comes from the ublue-os/packages
# COPR; Common's shared layer (already overlaid) supplies /etc/uupd/config.json,
# the AC-connect udev rule and service, the post-suspend timer, and the
# ConditionACPower drop-in — so a desktop updates on schedule and a laptop
# updates once it is on AC.
copr_install_isolated "ublue-os/packages" uupd

echo "::endgroup::"

###############################################################################
# Wayland desktop
#
# A Hyprland session on SDDM. Nothing here configures Hyprland or Quickshell:
# those are the user's to supply, and this image ships only the compositor, the
# shell, the display manager and the session file the RPMs provide. Without a
# hyprland.conf and a config.hypr there is no session to log into, which is a
# runtime concern and not a build one.
#
# Sources, and why each one:
#
#   hyprland   lionheartp/Hyprland COPR. Fedora 44 does not carry it at all.
#   quickshell same COPR. Fedora 44 has 0.2.1; the COPR has 0.3.1. The COPR
#              version is what pairs with the compositor above, so it wins.
#   sddm       Fedora 44 proper. No third-party repository needed.
#   tailscale  Fedora 44 proper. No third-party repository needed.
#   ghostty    Terra, via packages/terra.repo.
#
# Steam is deliberately absent. It is in Terra and it does install, but it pulls
# 32-bit libraries that need Fedora's openssl-libs, and Hummingbird pins its own
# rebuilt 3.5.8-0.1.hum1 through openssl-fips-provider-upstream. dnf5 refuses the
# transaction:
#
#   cannot install both openssl-libs-1:3.5.5-1.fc44.x86_64 from fedora-44 and
#   openssl-libs-1:3.5.8-0.1.hum1.x86_64 from @System
#
# --skip-broken would drop packages silently and ship a Steam that is missing
# libraries at unpredictable runtime, so it is not used. Installing Steam needs
# either a container-toolbox style chroot or a Fedora base; the image identity
# is not going to quietly absorb that.
###############################################################################

echo "::group:: Install the Hyprland compositor and Quickshell"

# copr_install_isolated rather than a bare `dnf5 copr enable`: it disables the
# COPR again immediately, so no third-party repo file ships enabled. The
# Containerfile's COPR_CHROOT is what makes the enable succeed here — without it
# dnf5 autodetects a chroot from os-release, gets hummingbird-20251124-x86_64,
# writes no repo file at all, and the install below fails with "No match for
# argument: hyprland".
copr_install_isolated "lionheartp/Hyprland" hyprland quickshell

echo "::endgroup::"

echo "::group:: Install SDDM and Tailscale"

# Both are in Fedora 44 proper. Tailscale is not a third-party repository
# dependency on this base, which is worth stating because the 30-tailscale
# example in build/ adds one.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y sddm tailscale

echo "::endgroup::"

echo "::group:: Install Ghostty from Terra"

# Terra was installed and enabled by the Containerfile's package sources phase,
# so it is live here without a per-step --enablerepo. 90-cleanup.sh closes it,
# along with fedora.repo, before the image is committed.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y ghostty

echo "::endgroup::"

echo "::group:: Enable desktop services"

# Enable explicitly rather than relying on the shipped preset, matching how
# 10-overlay.sh enables the Brew and Flatpak units. The base ships a preset
# that disables everything it does not name, so an explicit enable is the only
# thing that survives it.
#
# sddm is the display manager, so it takes over from the base's getty-on-tty
# arrangement. It has no session to offer until the user supplies a Hyprland
# configuration, which is expected: this image ships the compositor, not a
# desktop.
systemctl enable sddm.service

# tailscaled is what makes `tailscale up` work. socket-activated, so the unit
# is enough; the daemon starts on first use.
systemctl enable tailscaled.service

# Update policy, enabled here rather than in the uupd group above so that every
# service this image owns is enabled in one place.
systemctl enable uupd.timer
systemctl enable uupd-resume.timer

echo "::endgroup::"

# Restore default glob behavior
shopt -u nullglob
