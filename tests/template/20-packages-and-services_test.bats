#!/usr/bin/env bats
# Unit tests for build/20-packages-and-services.sh.
#
# This phase owns RPM and COPR installation, so the tests assert what it
# installs and the boundary around it: filesystem overlays and their units
# belong to 10-overlay.sh. The script sources /ctx/build/copr-helpers.sh, so
# each test rewrites a throwaway copy to point at a sandbox context and stubs
# dnf5, systemctl and rsync.
#
# Run with: bats tests/template/20-packages-and-services_test.bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_SRC="${REPO_ROOT}/build/20-packages-and-services.sh"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/20-packages.${BATS_TEST_NUMBER:-0}.$$"
	CTX="${TEST_ROOT}/ctx"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	SCRIPT="${TEST_ROOT}/20-packages-and-services.sh"

	DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
	SYSTEMCTL_LOG="${TEST_ROOT}/logs/systemctl.log"
	RSYNC_LOG="${TEST_ROOT}/logs/rsync.log"
	SLEEP_LOG="${TEST_ROOT}/logs/sleep.log"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs" "${CTX}/build"

	# The real helper library is sourced verbatim so a syntax break there fails
	# this suite too. dnf5-retry.sh is sourced by copr-helpers.sh relative to its
	# own location, so it has to sit beside it in the sandbox.
	cp "${REPO_ROOT}/build/copr-helpers.sh" "${CTX}/build/copr-helpers.sh"
	cp "${REPO_ROOT}/build/dnf5-retry.sh" "${CTX}/build/dnf5-retry.sh"

	sed -e "s#/ctx/#${CTX}/#g" "${BUILD_SRC}" >"${SCRIPT}"

	export PATH="${STUB_BIN}:${PATH}"
	export DNF5_LOG SYSTEMCTL_LOG RSYNC_LOG SLEEP_LOG
	# One attempt by default, so a test that stubs a failure gets a fast,
	# deterministic log rather than eight rounds of backoff.
	export DNF5_RETRY_ATTEMPTS=1

	for tool in dnf5 systemctl rsync; do
		local log_var
		log_var="$(printf '%s' "${tool}" | tr '[:lower:]' '[:upper:]')_LOG"
		cat >"${STUB_BIN}/${tool}" <<EOF
#!/usr/bin/bash
printf '%s\n' "\$*" >> "\${${log_var}}"
exit 0
EOF
		chmod +x "${STUB_BIN}/${tool}"
	done

	# dnf5_retry sleeps between attempts. Without this the retry tests would
	# spend real seconds waiting on a stub that never fails.
	cat >"${STUB_BIN}/sleep" <<'EOF'
#!/usr/bin/bash
printf 'sleep %s\n' "$*" >> "${SLEEP_LOG}"
exit 0
EOF
	chmod +x "${STUB_BIN}/sleep"
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

@test "20-packages-and-services: sandbox rewrite left no writes to the host filesystem" {
	# Guards the rewrite above: if the script's paths change, the sed no longer
	# matches and the suite would exec the real package provider.
	run grep -nE '(^|[^-[:alnum:]])/ctx/' "${SCRIPT}"
	[ "$status" -ne 0 ]

	grep -q "source ${CTX}/build/copr-helpers.sh" "${SCRIPT}"
}

@test "20-packages-and-services: completes successfully" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
}

@test "20-packages-and-services: emits GitHub Actions group markers" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"::group:: Install Default Packages"* ]]
	[[ "$output" == *"::group:: Install uupd"* ]]
	[[ "$output" == *"::group:: Install the audio stack"* ]]
	[[ "$output" == *"::group:: Install SDDM and Tailscale"* ]]
	[[ "$output" == *"::group:: Install Ghostty and MangoWM from Terra"* ]]
	[[ "$output" == *"::group:: Enable desktop services"* ]]
	[[ "$output" == *"::endgroup::"* ]]
}

@test "20-packages-and-services: installs the default packages in one dnf5 call" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${calls[0]}" = "install -y just gum fzf jq" ]
}

@test "20-packages-and-services: installs uupd from its COPR in isolation" {
	# copr_install_isolated enables the repo, disables it again, then installs
	# with a one-shot --enablerepo, so no COPR file persists enabled.
	# uupd is the only COPR left: the compositor moved to Terra, so this image
	# needs no COPR beyond ublue's own.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${calls[1]}" = "-y copr enable ublue-os/packages" ]
	[ "${calls[2]}" = "-y copr disable ublue-os/packages" ]
	[ "${calls[3]}" = "-y install --enablerepo=copr:copr.fedorainfracloud.org:ublue-os:packages uupd" ]
}

@test "20-packages-and-services: takes the compositor from Terra, not a COPR" {
	# MangoWM is published in both the lionheartp COPR and Terra. Terra is used
	# so the image needs no third-party COPR for its desktop, and because Terra
	# is already enabled for ghostty -- a COPR here would mean enabling and
	# disabling a second repository for a package the enabled one already has.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'install -y ghostty mangowm' "${DNF5_LOG}"
	run grep -q 'lionheartp' "${DNF5_LOG}"
	[ "$status" -ne 0 ]
}

@test "20-packages-and-services: installs the audio stack in one transaction" {
	# PipeWire and friends have to be named: neither SDDM nor MangoWM depends on
	# a sound server, and this base has no GNOME or Plasma pulling one in. An
	# installed system with no audio at all is the failure this prevents.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -q 'pipewire' "${DNF5_LOG}"
	grep -q 'wireplumber' "${DNF5_LOG}"
	# xdg-desktop-portal is not optional: it carries Flatpak permission prompts,
	# screen sharing and document portals.
	grep -q 'xdg-desktop-portal' "${DNF5_LOG}"
}

@test "20-packages-and-services: every COPR it touches is disabled again" {
	# The property that keeps a third-party repository out of the shipped image.
	# Each enable is immediately followed by its disable, and the install that
	# uses the repo does so through a one-shot --enablerepo.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# Counted with grep -c rather than a ((x++)) loop: `((x++))` exits non-zero
	# when the counter is still 0, which `set -e` in the test body would read as
	# a failure before the assertion ever runs.
	[ "$(grep -c 'copr enable' "${DNF5_LOG}")" -eq 1 ]
	[ "$(grep -c 'copr disable' "${DNF5_LOG}")" -eq 1 ]
}

@test "20-packages-and-services: installs the desktop set from the expected sources" {
	# sddm and tailscale come from Fedora proper, not a third-party repository.
	# Asserting the repo-less call is the point: it is what stops a later edit
	# from quietly adding a repository for something Fedora already ships.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -q 'install -y sddm tailscale' "${DNF5_LOG}"
	grep -qx 'install -y ghostty mangowm' "${DNF5_LOG}"
}

@test "20-packages-and-services: does not install Steam" {
	# Steam resolves in Terra but cannot be installed on this base: its 32-bit
	# dependencies need Fedora's openssl-libs, which conflicts with the
	# Hummingbird-rebuilt one already installed. Guarded so a later edit cannot
	# reintroduce it without someone reading the conflict first.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	run grep -cE '(^|[[:space:]])steam([[:space:]]|$)' "${DNF5_LOG}"
	[ "$output" -eq 0 ]
}

@test "20-packages-and-services: enables the display manager and tailscaled" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'enable sddm.service' "${SYSTEMCTL_LOG}"
	grep -qx 'enable tailscaled.service' "${SYSTEMCTL_LOG}"
}

@test "20-packages-and-services: names an explicit COPR chroot when the base needs one" {
	# `dnf5 copr enable` autodetects the chroot from the base's os-release. On a
	# base that does not report a Fedora release -- Hummingbird reports a build
	# date -- autodetection yields a chroot no COPR carries and the enable fails.
	# COPR_CHROOT is how the Containerfile supplies the right one.
	COPR_CHROOT="fedora-44-x86_64" run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${calls[1]}" = "-y copr enable ublue-os/packages fedora-44-x86_64" ]
}

@test "20-packages-and-services: the COPR chroot follows the base architecture" {
	# A hardcoded x86_64 chroot would break an arm64 build, so the value is read
	# from the environment rather than baked into the helper.
	COPR_CHROOT="fedora-44-aarch64" run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${calls[1]}" = "-y copr enable ublue-os/packages fedora-44-aarch64" ]
}

@test "20-packages-and-services: enables the update timers" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'enable uupd.timer' "${SYSTEMCTL_LOG}"
	grep -qx 'enable uupd-resume.timer' "${SYSTEMCTL_LOG}"
}

@test "20-packages-and-services: enables each service exactly once" {
	# The base ships a preset that disables anything it does not name, so a
	# duplicated enable is harmless at runtime but signals a copy-paste that
	# usually means something else was meant to be enabled too.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	local unit
	for unit in sddm.service tailscaled.service uupd.timer uupd-resume.timer; do
		[ "$(grep -cx "enable ${unit}" "${SYSTEMCTL_LOG}")" -eq 1 ]
	done
}

@test "20-packages-and-services: performs no overlays or service enablement beyond its own" {
	# Boundary guard for the phase split: the filesystem overlays belong to
	# 10-overlay.sh, so a package change never invalidates them.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[ ! -e "${RSYNC_LOG}" ]
}

@test "20-packages-and-services: sources copr-helpers.sh so copr_install_isolated is available" {
	cat >>"${SCRIPT}" <<'EOF'
declare -F copr_install_isolated >/dev/null && echo "HELPER_PRESENT"
EOF
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"HELPER_PRESENT"* ]]
}

@test "20-packages-and-services: fails fast when copr-helpers.sh is missing from the context" {
	rm -f "${CTX}/build/copr-helpers.sh"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
}

@test "20-packages-and-services: restores default glob behaviour before finishing" {
	cat >>"${SCRIPT}" <<'EOF'
shopt -q nullglob || echo "NULLGLOB_OFF"
EOF
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"NULLGLOB_OFF"* ]]
}
