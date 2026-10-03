#!/usr/bin/env bats
# Contract: the hardware and session phase.
#
# The property worth guarding here is not that the packages are listed. It is the
# three things about this base that are invisible until someone is on a machine
# with no network:
#
#   - linux-firmware is already installed and contains no WiFi firmware at all.
#     Omitting the per-vendor package produces an image that builds cleanly and
#     never associates.
#   - NetworkManager-wifi ships no systemd unit, so there is nothing to enable.
#     Naming one fails the build; this file pins that it is not named.
#   - bash-completion's hook is in profile.d, which login shells read and
#     desktop terminals do not. Without the bashrc wiring, completions work over
#     ssh and are missing in every window.
#
# Run with: bats tests/contract/hardware-session_test.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
CONTAINERFILE="${REPO_ROOT}/Containerfile"
PHASE="${REPO_ROOT}/build/25-hardware-and-session.sh"

@test "hardware-session: the phase runs after the desktop packages and before the kernel" {
	# After 20 because it is a distinct concern that should not invalidate the
	# desktop package layer when it changes. Before 30 because the kernel phase
	# swaps kernel packages out, and doing that after this one is what the
	# ordering is for.
	local phase_line desktop_line kernel_line
	phase_line="$(grep -n '/ctx/build/25-hardware-and-session.sh' "${CONTAINERFILE}" | head -n1 | cut -d: -f1)"
	desktop_line="$(grep -n '/ctx/build/20-packages-and-services.sh' "${CONTAINERFILE}" | head -n1 | cut -d: -f1)"
	kernel_line="$(grep -n '/ctx/build/30-kernel.sh' "${CONTAINERFILE}" | head -n1 | cut -d: -f1)"
	[ -n "${phase_line}" ]
	[ "${desktop_line}" -lt "${phase_line}" ]
	[ "${phase_line}" -lt "${kernel_line}" ]
}

@test "hardware-session: the phase step mounts the build context" {
	# The script is invoked as /ctx/build/25-hardware-and-session.sh, which only
	# exists if the ctx stage is bind mounted into that step. Omitting the mount
	# fails with exit 127 and "No such file or directory", which reads like a
	# missing script rather than a missing mount.
	local run_line
	run_line="$(grep -n '/ctx/build/25-hardware-and-session.sh' "${CONTAINERFILE}" | head -n1 | cut -d: -f1)"
	[ -n "${run_line}" ]
	local block
	block="$(sed -n "1,${run_line}p" "${CONTAINERFILE}" |
		tac | sed -n '/^RUN /,$p' | tac)"
	[[ "${block}" == *"--mount=type=bind,from=ctx,source=/,target=/ctx"* ]] || {
		printf 'FAIL: the RUN that calls 25-hardware-and-session.sh does not mount /ctx\n' >&2
		return 1
	}
}

@test "hardware-session: the phase script is executable" {
	# Invoked directly, not through `bash <path>`, so a lost execute bit fails
	# the build with exit 127.
	[ -x "${PHASE}" ] || {
		printf 'FAIL: 25-hardware-and-session.sh is not executable\n' >&2
		return 1
	}
}

@test "hardware-session: the WiFi stack is named" {
	# Without NetworkManager-wifi NetworkManager runs, manages everything else,
	# and reports no wireless hardware at all.
	run grep -q 'NetworkManager-wifi' "${PHASE}"
	[ "$status" -eq 0 ]
	# wpa_supplicant is what NetworkManager drives; iw is the diagnostic tool
	# that has to be present before there is a network to install it over.
	run grep -q 'wpa_supplicant' "${PHASE}"
	[ "$status" -eq 0 ]
	run grep -qE '^[[:space:]]*iw$' "${PHASE}"
	[ "$status" -eq 0 ]
}

@test "hardware-session: all three Intel firmware packages are installed" {
	# The property that matters: the base already carries linux-firmware and it
	# holds 1848 files of which exactly one mentions iwlwifi, and that one is the
	# licence. The blobs are in per-vendor packages. Which of the three applies
	# depends on the card, and a wrong guess means no network with no error.
	local pkg
	for pkg in iwlwifi-mvm-firmware iwlwifi-mld-firmware iwlwifi-dvm-firmware; do
		run grep -q "${pkg}" "${PHASE}"
		[ "$status" -eq 0 ] || {
			printf 'FAIL: %s is not installed by the phase\n' "${pkg}" >&2
			return 1
		}
	done
}

@test "hardware-session: the phase asserts firmware blobs are on disk" {
	# Installed is not the same as present, and the failure this guards is the
	# one the base itself exhibits: the package installs and the blobs are not
	# there. Matching the directory rather than a file extension, because the
	# blobs ship as .ucode.xz and a pattern for bare .ucode matches nothing
	# while the firmware is perfectly correct.
	run grep -qF '/usr/lib/firmware/intel/iwlwifi/iwlwifi-*' "${PHASE}"
	[ "$status" -eq 0 ]
	# And it must not pin a bare .ucode, which would fail against real firmware.
	run grep -qF 'iwlwifi-*.ucode"' "${PHASE}"
	[ "$status" -ne 0 ]
}

@test "hardware-session: no NetworkManager-wifi unit is enabled" {
	# NetworkManager-wifi ships no systemd unit. NetworkManager loads the plugin
	# itself. `systemctl enable` on a unit that does not exist fails the build,
	# so the phase checks for presence first and the test pins that no unit name
	# is hard-coded into an enable.
	local enable_calls
	enable_calls="$(grep -E 'enable_if_present ' "${PHASE}" | grep -c 'NetworkManager-wifi' || true)"
	[ "${enable_calls}" -eq 0 ]
	# The presence guard is what makes the whole approach safe.
	run grep -q 'list-unit-files' "${PHASE}"
	[ "$status" -eq 0 ]
}

@test "hardware-session: wpa_supplicant is installed but its service is not enabled" {
	# NetworkManager starts the supplicant on demand. Enabling the unit makes a
	# second, unmanaged instance fight the first.
	run grep -q 'wpa_supplicant' "${PHASE}"
	[ "$status" -eq 0 ]
	run grep -E 'enable_if_present .*wpa_supplicant' "${PHASE}"
	[ "$status" -ne 0 ]
}

@test "hardware-session: a polkit agent is installed" {
	# Without one, every password-gated action -- mounting a disk, changing a
	# network, a GUI install -- fails with no prompt and no explanation.
	run grep -q 'lxpolkit' "${PHASE}"
	[ "$status" -eq 0 ]
	# polkit-gnome is not in Fedora 44, which is why this is the heavyweight
	# option it is. Named in the comment so a future reader knows it was a
	# measured choice rather than the first one that installed.
	run grep -q 'polkit-gnome is not in Fedora 44' "${PHASE}"
	[ "$status" -eq 0 ]
}

@test "hardware-session: bluetooth, power and firmware services are enabled" {
	local unit
	for unit in bluetooth.service power-profiles-daemon.service upower.service fwupd-refresh.timer; do
		run grep -q "enable_if_present ${unit}" "${PHASE}"
		[ "$status" -eq 0 ] || {
			printf 'FAIL: %s is not enabled by the phase\n' "${unit}" >&2
			return 1
		}
	done
	# fwupd itself must stay off: it is D-Bus activated, and the timer is what
	# starts work. Enabling the service duplicates the socket.
	run grep -E 'enable_if_present .*fwupd\.service' "${PHASE}"
	[ "$status" -ne 0 ]
}

@test "hardware-session: the bash completion hook targets /etc/bashrc, not profile.d" {
	# profile.d is read by login shells only. A terminal emulator starts a
	# non-login interactive shell, which reads ~/.bashrc and nothing else, so a
	# hook there works over ssh and is absent from every window on the desktop.
	run grep -q 'BASHRC_PATH=/etc/bashrc' "${PHASE}"
	[ "$status" -eq 0 ]
	# And it must be an append, not a replacement: custom/files rsyncs over the
	# root, and shipping a whole bashrc through it would freeze the distro's
	# copy for the life of the image.
	run grep -q 'cat >>"\${BASHRC_PATH}"' "${PHASE}"
	[ "$status" -eq 0 ]
	run grep -qE '(cp|mv|install) .*\${BASHRC_PATH}' "${PHASE}"
	[ "$status" -ne 0 ]
}

@test "hardware-session: the bashrc append is idempotent" {
	# The phase may run again on a rebuild. Appending unconditionally would grow
	# the file and source the completion set repeatedly.
	run grep -q 'grep -qF "\${BASHRC_MARKER}"' "${PHASE}"
	[ "$status" -eq 0 ]
}

@test "hardware-session: the completions check simulates an interactive shell" {
	# PS1 must be assigned inside the child shell. bash unsets PS1 in a
	# non-interactive shell even when exported, so an environment prefix makes
	# the hook's own guard see no prompt, skip itself, and report zero
	# completions for an image that is working perfectly.
	run grep -qF "bash -c 'PS1=\"\$ \"" "${PHASE}"
	[ "$status" -eq 0 ]
	# And it goes through the skel .bashrc, because that is the path a real new
	# account takes and it is the only thing that proves the wiring is reachable.
	run grep -qF '. /etc/skel/.bashrc' "${PHASE}"
	[ "$status" -eq 0 ]
}

@test "hardware-session: the phase installs bash-completion itself" {
	# It is easy to wire the hook and forget the package: the hook's own guard is
	# `[ -r ... ]`, so a missing package makes it silently do nothing and the
	# image looks fine until someone types a tab.
	run grep -q 'install -y bash-completion' "${PHASE}"
	[ "$status" -eq 0 ]
}

@test "hardware-session: the phase does not install CLI tools the Brewfile already has" {
	# The dividing line from the customize skill: what the image must have goes
	# here, what the user chooses goes in the Brewfile. The default Brewfile
	# already carries ripgrep, bat, eza, fzf, zoxide and gh, so duplicating them
	# here is two copies of the same tool at two versions.
	local tool
	for tool in ripgrep bat eza zoxide gh neovim tmux; do
		run grep -E "^[^#]*[[:space:]]${tool}[[:space:]]*\\\\?$" "${PHASE}"
		[ "$status" -ne 0 ] || {
			printf 'FAIL: %s is installed here but is already in the Brewfile\n' "${tool}" >&2
			return 1
		}
	done
}

@test "hardware-session: AMD GPU firmware is not installed" {
	# This image uses the NVIDIA driver. amd-gpu-firmware is 28 MB for cards this
	# image does not drive, and its presence would suggest otherwise.
	run grep -E '^[^#]*amd-gpu-firmware' "${PHASE}"
	[ "$status" -ne 0 ]
}
