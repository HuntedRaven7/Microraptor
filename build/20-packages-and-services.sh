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

if [ -f /usr/lib/systemd/logind.conf ]; then
    sed -i 's/^#HandleLidSwitch=.*/HandleLidSwitch=suspend-then-hibernate/' /usr/lib/systemd/logind.conf
    sed -i 's/^#HandleLidSwitchDocked=.*/HandleLidSwitchDocked=suspend-then-hibernate/' /usr/lib/systemd/logind.conf
    sed -i 's/^#HandleLidSwitchExternalPower=.*/HandleLidSwitchExternalPower=suspend-then-hibernate/' /usr/lib/systemd/logind.conf
    sed -i 's/^#SleepOperation=.*/SleepOperation=suspend-then-hibernate/' /usr/lib/systemd/logind.conf
fi

unit_exists() {
    systemctl cat "$1" >/dev/null 2>&1
}

user_unit_exists() {
    for dir in /usr/lib/systemd/user /usr/local/lib/systemd/user /etc/systemd/user; do
        [ -e "$dir/$1" ] && return 0
    done
    return 1
}

enable_unit() {
    unit_exists "$1" && systemctl enable "$1" || true
}

disable_unit() {
    unit_exists "$1" && systemctl disable "$1" || true
}

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
# A MangoWM session on SDDM. Nothing here configures MangoWM: the compositor, the
# display manager and the session file the RPMs provide are the whole
# deliverable. A session that exits immediately until you supply a configuration
# is a runtime concern, not a build one.
#
# Sources, and why each one:
#
#   mangowm   Terra, 0.17.5-3.fc44. Not in Fedora 44.
#   sddm      Fedora 44 proper. No third-party repository needed.
#   tailscale Fedora 44 proper. No third-party repository needed.
#   ghostty   Terra, via packages/terra.repo.
#   pipewire  Fedora 44 proper. See the note below on why it is listed.
#
# This was Hyprland and Quickshell for one commit. Both came from the
# lionheartp/Hyprland COPR, which is also where MangoWM is published -- but Terra
# carries it too, and taking it from Terra means this image needs no third-party
# COPR at all. Quickshell went with the swap: it is the shell Hyprland's
# ecosystem is built around, and MangoWM has no equivalent role for it. Nothing
# else in the image depends on it.
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



echo "::group:: Install the audio stack"

# PipeWire, WirePlumber and the desktop portal, all in Fedora 44 proper.
#
# Listed explicitly because neither SDDM nor MangoWM pulls them. A compositor
# links libpulse and libpipewire if it wants audio, but nothing here depends on a
# sound server, and this base has no GNOME or Plasma to pull one in. Without
# them an installed system has no audio at all.
#
# xdg-desktop-portal is the one that is easy to overlook and is not optional: it
# is how a session talks to the host for Flatpak permission prompts, screen
# sharing and document portals. Without it those silently stop working.
#
# pipewire-alsa is the ALSA compatibility layer, so ordinary desktop apps that
# only speak ALSA still produce sound.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
	pipewire \
	pipewire-alsa \
	pipewire-utils \
	wireplumber \
	xdg-desktop-portal \
	xdg-desktop-portal-gtk
        NetworkManager-config-connectivity-fedora \
	NetworkManager-wifi \
	wpa_supplicant \
	wireless-regdb \
	ModemManager \
	NetworkManager-wwan \
	NetworkManager-bluetooth \
	bind-utils \
	iptables-nft \
	linux-firmware \
	wlwifi-dvm-firmware \
	iwlwifi-mvm-firmware \
	iwlwifi-mld-firmware \
	iwlegacy-firmware \
	dbus-devel \
	iw

echo "::endgroup::"

echo "::group:: Install SDDM and Tailscale"

# Both are in Fedora 44 proper. Tailscale is not a third-party repository
# dependency on this base, which is worth stating because the 30-tailscale
# example in build/ adds one.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y sddm tailscale

echo "::endgroup::"

echo "::group:: Install Ghostty and MangoWM from Terra"

# Terra was installed and enabled by the Containerfile's package sources phase,
# so it is live here without a per-step --enablerepo. 90-cleanup.sh closes it,
# along with fedora.repo, before the image is committed.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y ghostty mangowm

echo "::endgroup::"

echo "::group:: Enable desktop services"

# Enable explicitly rather than relying on the shipped preset, matching how
# 10-overlay.sh enables the Brew and Flatpak units. The base ships a preset
# that disables everything it does not name, so an explicit enable is the only
# thing that survives it.
#
# sddm is the display manager, so it takes over from the base's getty-on-tty
# arrangement. It has no session to offer until the user supplies a MangoWM
# configuration, which is expected: this image ships the compositor, not a
# desktop.
systemctl enable sddm.service
enable_unit bluetooth.service
enable_unit systemd-resolved.service
enable_unit ModemManager.service

for unit in pipewire.socket pipewire-pulse.socket wireplumber.service \
            xdg-user-dirs.service \
            obex.service mpris-proxy.service; do
    if user_unit_exists "${unit}"; then
        systemctl --global enable "${unit}"
    else
        echo "user unit ${unit} is not installed; skipping" >&2
    fi
done

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
