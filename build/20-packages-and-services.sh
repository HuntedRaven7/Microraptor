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

dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y just fzf jq

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
#   quickshell lionheartp/Hyprland COPR. Fedora 44 has 0.2.1; the COPR has 0.3.1.
#              The COPR version is what current shell configs target, so it wins.
#   tailscale Fedora 44 proper. No third-party repository needed.
#   ghostty   Terra, via packages/terra.repo.
#   pipewire  Fedora 44 proper. See the note below on why it is listed.
#
# This was Hyprland and Quickshell for one commit, both from the same COPR, and
# only the compositor moved -- to Terra, which also carries MangoWM. Quickshell
# stayed on the COPR and is still the point: it is a Qt/QML toolkit for building
# bars, widgets, notifications and lock screens, and it is what the MangoWM
# ecosystem is actually built on. Kamalen Shell and Caelestia are both Quickshell
# configurations written for MangoWM, so shipping the compositor without the
# toolkit leaves the user with a barless session and no obvious way to add one.
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

echo "::group:: Install Quickshell and Hyprland"

# Quickshell is the toolkit MangoWM's shell ecosystem is built on, and it comes
# from the same COPR the compositor used to come from. It stayed when the
# compositor moved to Terra.
#
# Removed for one commit on the reasoning that Quickshell belonged to Hyprland
# and had no role under MangoWM. That was wrong, and it was an assumption rather
# than a check: Quickshell is compositor-agnostic and is used with Niri and
# MangoWC as much as with Hyprland, and the well-known shells for this compositor
# -- Kamalen, Caelestia -- are Quickshell configurations. A build phase should not
# be where that gets decided by guesswork.
#
# copr_install_isolated rather than a bare `dnf5 copr enable`: it disables the
# COPR again immediately, so no third-party repo file ships enabled. The
# Containerfile's COPR_CHROOT is what makes the enable succeed here -- without it
# dnf5 autodetects a chroot from os-release, gets hummingbird-20251124-x86_64,
# writes no repo file at all, and the install below fails with "No match for
# argument: quickshell".
copr_install_isolated "lionheartp/Hyprland" quickshell hyprland

echo "::endgroup::"

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
	wireless-regdb \
	wlr-randr

echo "::endgroup::"

echo "::group:: Install the Utah package stack"

# Grouped by what each set is for rather than left as one flat run, because at
# 68 packages the middle of an alphabetical list tells a reader nothing about why
# anything is there.
#
# This is an array rather than a backslash-continued list because a comment inside
# a continued command does not work: bash ends the command at the `#`, runs it
# with whatever came before, and then tries to execute the next package name as a
# command. `bash -n` accepts it, so only running it catches the difference. An
# array literal takes comments between its elements and still expands to a single
# argument list, which keeps the install one transaction.
utah_packages=(
	NetworkManager-config-connectivity-fedora
	niri
	NetworkManager-wifi
	NetworkManager-wwan
	wpa_supplicant
	iw
	wireless-regdb
	ModemManager
	bind-utils
	iptables-nft
	NetworkManager-bluetooth
	fprintd
	fprintd-pam
	linux-firmware
	iwlwifi-dvm-firmware
	iwlwifi-mld-firmware
	iwlwifi-mvm-firmware
	iwlegacy-firmware
	intel-gmmlib
	intel-mediasdk
	intel-vpl-gpu-rt
	libheif
	libva
	libva-intel-media-driver
	mesa-dri-drivers
	mesa-filesystem
	mesa-libEGL
	mesa-libGL
	mesa-libgbm
	mesa-vulkan-drivers
	alsa-ucm
	alsa-utils
	pipewire-alsa
	gdm
	pipewire-utils
	wireplumber
	xdg-desktop-portal
	langpacks-en
	langpacks-fonts-en
	abattis-cantarell-fonts
	default-fonts-core-emoji
	default-fonts-core-mono
	default-fonts-core-sans
	default-fonts-core-serif
	google-noto-sans-math-fonts
	google-noto-sans-mono-vf-fonts
	google-noto-sans-symbols-2-fonts
	google-noto-serif-vf-fonts
	bash-completion
	crypto-policies-scripts
	dbus-tools
	file
	hostname
	keyutils
	less
	libimobiledevice-utils
	lm_sensors
	man-db
	poppler-utils
	unzip
	which
	wlr-randr
	xxd
	zip
	buildah
	cups
	cups-client
	cups-ipptool
	python3-pip
	systemd-container
)

dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y "${utah_packages[@]}"

echo "::endgroup::"



echo "::group:: Install SDDM and Tailscale"

# Both are in Fedora 44 proper. Tailscale is not a third-party repository
# dependency on this base, which is worth stating because the 30-tailscale
# example in build/ adds one.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y tailscale

echo "::endgroup::"

echo "::group:: Install Ghostty and MangoWM from Terra"

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
# arrangement. It has no session to offer until the user supplies a MangoWM
# configuration, which is expected: this image ships the compositor, not a
# desktop.
systemctl enable gdm.service

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

# Close the Utah package factory now that this phase is the last thing in the
# build that needs it.
#
# utah.repo is copied to /etc/yum.repos.d enabled=1 and points at
# file:///etc/utah-packages, a path that exists only while the factory image is
# bind mounted there. That mount is on three steps -- the package-sources phase,
# 10-overlay.sh and this one -- and not on the phases that follow. So leaving the
# repository enabled makes every later dnf5 call fail to fetch its metadata:
#
#   Failed to download metadata (baseurl: "file:///etc/utah-packages") for
#   repository "utah-packages": Usable URL not found
#
# dnf5 reports that as a warning and carries on, so it does not always stop the
# build, which is what makes it worth closing rather than ignoring: 40-nvidia.sh
# retries `makecache --refresh` eight times against a path that is not there and
# burns a minute and a half before continuing.
#
# The flip belongs at the end of this phase rather than after the Utah group,
# because two more dnf5 transactions follow the group -- SDDM/Tailscale and
# Ghostty/MangoWM -- and those run while the factory is still mounted.
#
# packages/utah.repo says this step used to be 90-cleanup.sh. That was correct
# when this phase was the last one that installed anything; it stopped being true
# when the hardware, kernel and NVIDIA phases were added after it. Closing it
# here puts it immediately after the last use instead of trusting the order of
# phases that run dnf5.
#
# Guarded, because the file is copied in by the Containerfile and must be there,
# and failing the build when it is not is better than a silently live repository.
if [[ -f /etc/yum.repos.d/utah.repo ]]; then
	sed -i 's/^enabled=1$/enabled=0/' /etc/yum.repos.d/utah.repo
	echo "::group:: Finalise the Utah package factory"
	if grep -qE '^enabled=1' /etc/yum.repos.d/utah.repo; then
		echo "::error::utah-packages is still enabled in /etc/yum.repos.d/utah.repo" >&2
		exit 1
	fi
	echo "utah-packages: enabled=0 (the factory mount does not survive this phase)"
	echo "::endgroup::"
else
	echo "::error::/etc/yum.repos.d/utah.repo is missing; cannot close the package factory" >&2
	exit 1
fi

# Restore default glob behavior
shopt -u nullglob
