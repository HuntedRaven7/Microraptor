#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Hardware and session plumbing
#
# Everything the base leaves out that a laptop or a desktop cannot do without,
# and the two pieces of session wiring that no package installs on its own.
#
# Split out from 20-packages-and-services.sh rather than appended to it, because
# this set has a different kind of justification. 20 installs what the image
# *is*; this installs what the image needs in order to *function*, and the
# reasoning is per-package rather than a list -- a reader who wants to know why
# the WiFi firmware is 147 MB needs a different explanation than one checking
# whether just and jq are present.
#
# Three things here are not obvious, and each was verified against the base
# rather than assumed:
#
#  1. The base ships linux-firmware, and that package contains no WiFi firmware
#     at all. It is 1848 files and exactly one of them mentions iwlwifi -- the
#     licence. In Fedora 44 the vendor blobs are separate packages and none was
#     pulled in, so NetworkManager can see the adapter and never bring it up.
#     This is the single most surprising thing about adding WiFi to this base.
#
#  2. NetworkManager-wifi ships no systemd unit. There is nothing to enable;
#     NetworkManager loads the plugin itself. Enabling a unit that does not
#     exist fails the build, and guessing one is how that happens.
#
#  3. bash-completion's hook lives in /etc/profile.d, which only *login* shells
#     read. A terminal emulator starts a non-login interactive shell, so the
#     completions silently do not load where the user is actually typing. The
#     /etc/bashrc wiring further down is what fixes that.
###############################################################################

# shellcheck source=/dev/null
source /ctx/build/copr-helpers.sh

# Not cosmetic. Every glob below expands a set of package names, and without
# nullglob an unmatched pattern is passed to dnf5 as a literal -- which fails,
# or worse, matches a package by a name nobody intended.
shopt -s nullglob

echo "::group:: Install the WiFi stack"

# NetworkManager-wifi is the plugin that gives NetworkManager the ability to
# manage a wireless connection at all. Without it NetworkManager runs and does
# everything else, and reports no wireless hardware.
#
# wpa_supplicant is the supplicant NetworkManager drives. iwd is the modern
# alternative and is not installed: wpa_supplicant is what Fedora's own
# integration tests and the overwhelming majority of tooling assume, and picking
# the other one here buys nothing on a single image.
#
# iw is the diagnostic tool. Small, and the first thing anyone reaches for when
# a connection will not come up -- without it, diagnosing WiFi means installing
# something on the machine that has no network.
#
# 5 packages, 8 MB. Everything expensive about WiFi is the firmware below.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
	NetworkManager-wifi \
	wpa_supplicant \
	iw

echo "::endgroup::"

echo "::group:: Install the Intel WiFi firmware"

# This is the part that surprises people. The base already carries
# linux-firmware, and it is not enough: that package holds 1848 files and exactly
# one reference to iwlwifi, which is the licence file. The actual blobs live in
# per-vendor packages, and none of them is installed. So without this group a
# machine with an Intel card sees the adapter in hardware and never associates.
#
# All three Intel packages rather than picking one, because which of them applies
# depends on the card and the failure is total -- no network, no error worth the
# name:
#
#   iwlwifi-mvm-firmware   98 MB  modern Intel: AX200/AX210/AX300, BE, 6E
#   iwlwifi-mld-firmware   35 MB  the MLD variants of the above (AX210+, BE200)
#   iwlwifi-dvm-firmware   14 MB  legacy cards that predate the mvm driver
#
# Realtek is 7 MB and MediaTek 5 MB if this ever runs on one of those; a Broadcom
# card wants brcmfmac-firmware (10 MB). Adding one is a line, not a redesign.
#
# amd-gpu-firmware (28 MB) is deliberately NOT here. The NVIDIA driver is what
# this image uses for the GPU, and that firmware is for AMD cards.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
	iwlwifi-mvm-firmware \
	iwlwifi-mld-firmware \
	iwlwifi-dvm-firmware

echo "::endgroup::"

echo "::group:: Install the session plumbing"

# A compositor on its own is not a desktop. These are the parts that turn a
# running window manager into one a person can work in.
#
# bluez and bluez-tools: Bluetooth. Bluez-libs is already in the base, so the
# stack was half-present and inert -- the kernel module loaded and nothing spoke
# to it. bluez-tools is ncurses-based, so `bluetoothctl` works over SSH on a
# machine with no desktop, which is the situation where you actually need it.
#
# lxpolkit is the polkit authentication agent. Without one, every action that
# needs a password -- mounting a disk, changing a network, installing anything
# with a GUI -- fails with no prompt and no explanation, which is a genuinely
# baffling failure to debug from the inside. It is named lxqt because that is
# where it comes from, but it is a standalone agent that autostarts in any XDG
# session through /etc/xdg/autostart/lxpolkit.desktop; it does not pull in LXQt.
#
# It costs 98 MB and 67 packages, and that is the price of the obvious
# alternative: polkit-gnome is not in Fedora 44. Checked before settling on this
# rather than assumed -- polkit-kde and mate-polkit are also present and are
# heavier still, at 98 MB and 173 MB respectively.
#
# gvfs gives the file manager and desktop access to GVFS mounts -- MTP for a
# phone, SMB for a NAS, and the trash and recent-files support. gvfs-mtp is the
# phone one, which is the common case and the reason gvfs is here at all.
# Without it a plugged-in phone is simply invisible.
#
# xdg-utils provides xdg-open, xdg-mime and the rest -- the layer that knows
# which application owns which file type. xdg-user-dirs creates ~/Documents,
# ~/Downloads and the rest on first login and is autostarted; it is tiny and its
# absence leaves a home directory that looks wrong in every file manager.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
	bluez \
	bluez-tools \
	lxpolkit \
	gvfs \
	gvfs-mtp \
	xdg-utils \
	xdg-user-dirs

echo "::endgroup::"

echo "::group:: Install the laptop power and firmware management stack"

# power-profiles-daemon is the GNOME power-profiles daemon, which despite the
# name is not GNOME-specific -- it is a D-Bus interface and a daemon, and it is
# the only thing that gives a laptop a working power-mode control. Without it
# the machine sits in whatever profile the firmware picked and there is no way
# to change it.
#
# upower reports battery state and charge thresholds. On a desktop it is inert;
# on a laptop it is what answers "how much charge is left".
#
# fwupd updates the firmware that is not the kernel's business: the system BIOS,
# Thunderbolt controllers, and the peripheral firmware that would otherwise need
# a vendor tool and a reboot. The timer is what makes it check; the service
# itself is D-Bus activated and must not be enabled.
#
# tuned, which the base already carries, configures the kernel and CPU governor.
# power-profiles-daemon and tuned overlap here, which is deliberate: tuned
# profiles describe servers, power-profiles-daemon describes a battery. tuned is
# left as the base ships it.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
	power-profiles-daemon \
	upower \
	fwupd

echo "::endgroup::"

echo "::group:: Wire bash completions into non-login shells"

# The package itself, installed here rather than in an earlier group because this
# is the only thing in the phase that uses it. 191 completion scripts covering
# git, systemctl, dnf5, tar, ssh and the rest of the system tooling; the tools
# themselves each ship their own completions as subpackages and those arrive with
# their own installs.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y bash-completion

if [[ ! -r /usr/share/bash-completion/bash_completion ]]; then
	echo "::error::bash-completion installed but /usr/share/bash-completion/bash_completion is missing" >&2
	exit 1
fi

# bash-completion's own hook is /etc/profile.d/bash_completion.sh, and a login
# shell gets it: sourcing that hook registers 131 completions. Verified.
#
# A desktop terminal does not, and that is the case that matters. bash reads
# /etc/profile only for a login shell; a terminal emulator starts a non-login
# interactive shell, which reads ~/.bashrc and nothing else. So installing the
# package and stopping there gives an image where completions work over ssh and
# are missing in every window on the desktop.
#
# /etc/bashrc is the seam that closes it. /etc/skel/.bashrc sources /etc/bashrc
# on the way in, so one guarded block there covers every interactive shell for
# every new account, and root.
#
# Appended, never replaced. custom/files/ rsyncs over the root, and shipping a
# whole /etc/bashrc through it would freeze the distro's copy for the life of the
# image -- every future bashrc fix silently lost. An append with a marker is
# idempotent, survives this phase running twice, and leaves the file's contents
# to the package that owns it.
BASHRC_MARKER='# microraptor: bash completions'
BASHRC_PATH=/etc/bashrc

# Guarded on the marker so a rebuild does not append the block a second time.
if grep -qF "${BASHRC_MARKER}" "${BASHRC_PATH}"; then
	echo "bash completion hook already present in ${BASHRC_PATH}"
else
	cat >>"${BASHRC_PATH}" <<'HOOK'

# microraptor: bash completions
#
# /etc/profile.d/bash_completion.sh only covers login shells. This is sourced
# from ~/.bashrc on the way to a non-login interactive shell -- which is what a
# terminal emulator starts -- so this is the line that makes completions work
# where the user is actually typing. Interactive only, and idempotent.
if [ -n "${BASH_VERSION:-}" ] && [ -n "${PS1:-}" ]; then
	if [ -r /usr/share/bash-completion/bash_completion ]; then
		# shellcheck source=/dev/null
		. /usr/share/bash-completion/bash_completion
	fi
fi
HOOK
	echo "appended the completion hook to ${BASHRC_PATH}"
fi

# Assert the result rather than trusting the append. A block that landed in the
# wrong file, or a bashrc that does not run it, is invisible until someone
# notices they have no completions.
if ! grep -qF "${BASHRC_MARKER}" "${BASHRC_PATH}"; then
	echo "::error::the bash completion hook is not in ${BASHRC_PATH}" >&2
	exit 1
fi

echo "::endgroup::"

echo "::group:: Enable the hardware services"

# Enabled explicitly rather than relying on the shipped preset, matching the rest
# of the build. The base disables every unit it does not name, so an explicit
# enable is the only thing that survives it.
#
# Each one is checked for existence first. `systemctl enable` on a unit that is
# not installed fails the build, and the set of units these packages ship moves
# between releases -- NetworkManager-wifi, the obvious candidate here, ships
# none at all. Guessing a unit name is how a phase that is correct in principle
# breaks on a base bump.
#
# Deliberately NOT enabled, and why:
#
#   NetworkManager-wifi.service  does not exist. NetworkManager loads the plugin
#                                itself; there is nothing to start.
#   wpa_supplicant.service       NetworkManager starts the supplicant on demand.
#                                Enabling it makes a second, unmanaged instance
#                                fight the first.
#   fwupd.service                D-Bus activated. Enabling a D-Bus unit does
#                                nothing useful and duplicates the socket.
#   fwupd-refresh.service        static, pulled in by the timer.
#   gvfs-*.service               user units, D-Bus activated per session.
#   xdg-user-dirs.service        a user unit, and it has an autostart entry.
#   lxpolkit                     no unit; autostarts via /etc/xdg/autostart.
enable_if_present() {
	local unit="$1"
	if ! systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
		echo "${unit} is not provided by this base; nothing to enable"
		return 0
	fi
	if [[ "$(systemctl list-unit-files "${unit}" --no-legend 2>/dev/null | awk '{print $2}')" == "masked" ]]; then
		echo "::error::${unit} is masked; refusing to enable it" >&2
		exit 1
	fi
	systemctl enable "${unit}"
}

# Bluetooth. The kernel side is already present via bluez-libs, so without this
# the adapter is detected and never usable.
enable_if_present bluetooth.service

# The power-mode daemon and the battery reporter. Both are per-user on a desktop
# and the daemon additionally needs to be up before a session asks it anything.
enable_if_present power-profiles-daemon.service
enable_if_present upower.service

# The firmware update check. The timer, not the service: fwupd itself is started
# on demand by whatever asks it to do work.
enable_if_present fwupd-refresh.timer

echo "::endgroup::"

echo "::group:: Verify"

# The checks that can be made without the hardware, chosen because each one is a
# failure the build would otherwise ship silently.
#
# Firmware is the important one. Its absence produces no error at install time
# and no error at boot -- the adapter is simply there and never associates, which
# looks like a driver bug and is not.
for firmware in iwlwifi-mvm-firmware iwlwifi-mld-firmware iwlwifi-dvm-firmware; do
	if ! rpm -q "${firmware}" >/dev/null 2>&1; then
		echo "::error::${firmware} is not installed; an Intel WiFi card will not associate" >&2
		exit 1
	fi
done
echo "Intel WiFi firmware: present"

# Assert there are actual blobs, not just the licence file the base's
# linux-firmware carries. This is the check that would have caught the original
# problem, and it is cheap.
#
# The glob stops at the directory rather than naming an extension: the blobs ship
# as .ucode.xz, and a pattern for bare .ucode matches nothing while the firmware
# is installed perfectly correctly. Matching the extension is how that check ends
# up reporting a working image as broken.
if ! compgen -G '/usr/lib/firmware/intel/iwlwifi/iwlwifi-*' >/dev/null 2>&1; then
	echo "::error::no iwlwifi firmware blobs on disk despite the packages being installed" >&2
	echo "::error::check what iwlwifi-mvm-firmware actually ships: rpm -ql iwlwifi-mvm-firmware | head" >&2
	exit 1
fi
echo "iwlwifi blobs: $(find /usr/lib/firmware/intel/iwlwifi -type f | wc -l)"

# NetworkManager-wifi present, and no unit to enable. Both halves asserted,
# because the first without the second would mean a phase that fails on the
# enable, and the second without the first would mean a phase quietly doing
# nothing for WiFi.
if ! rpm -q NetworkManager-wifi >/dev/null 2>&1; then
	echo "::error::NetworkManager-wifi is not installed" >&2
	exit 1
fi
if systemctl list-unit-files 'NetworkManager-wifi*' >/dev/null 2>&1; then
	echo "::warning::this base ships a NetworkManager-wifi unit; check whether it wants enabling" >&2
fi
echo "NetworkManager-wifi: installed, no unit required"

# The services this phase claimed to enable, actually enabled. `is-enabled` is
# the check that matters; a successful `systemctl enable` in a build container
# and a unit enabled in the committed image are the same thing here only because
# enable writes a symlink into /etc, which does land in the image.
for unit in bluetooth.service power-profiles-daemon.service upower.service fwupd-refresh.timer; do
	if ! systemctl list-unit-files "${unit}" >/dev/null 2>&1; then
		continue
	fi
	if [[ "$(systemctl is-enabled "${unit}" 2>/dev/null)" != "enabled" ]]; then
		echo "::error::${unit} is $(systemctl is-enabled "${unit}" 2>&1), expected enabled" >&2
		exit 1
	fi
done
echo "hardware services: enabled"

# bash-completion really does register completions when its hook is sourced.
# Checked by counting, because "the file exists" is not the property anyone
# cares about.
#
# PS1 is assigned *inside* the child shell, not as an environment prefix. bash
# unsets PS1 in a non-interactive shell even when it is exported, so an
# environment prefix makes the guard in the hook below see no prompt, skip
# itself, and report zero completions for an image that is working perfectly.
# A shell-variable assignment is what an interactive shell actually has, which
# is the thing being simulated.
completion_count="$(bash -c 'PS1="$ "; . /usr/share/bash-completion/bash_completion; complete -p | wc -l')"
if [[ "${completion_count}" -lt 50 ]]; then
	echo "::error::only ${completion_count} completions registered; expected the full set" >&2
	exit 1
fi
echo "bash completions: ${completion_count} registered"

# And the hook is reachable from a non-login interactive shell, which is the
# whole point of the /etc/bashrc wiring above. Simulated rather than asserted
# structurally: this is the behaviour, and the structure is only a means to it.
# A real terminal also sources ~/.bashrc on the way to /etc/bashrc; the skel
# .bashrc on this base does exactly that, and it is what makes the block below
# reachable for a new account.
via_bashrc="$(bash -c 'PS1="$ "; . /etc/skel/.bashrc; complete -p | wc -l')"
if [[ "${via_bashrc}" -lt 50 ]]; then
	echo "::error::completions do not load via the skel .bashrc; desktop terminals get none" >&2
	echo "::error::skel .bashrc must source /etc/bashrc for the hook to be reachable" >&2
	exit 1
fi
echo "completions load through the skel .bashrc -> /etc/bashrc chain"

echo "::endgroup::"
