#!/usr/bin/env bats
# Unit tests for build/20-server-base.sh.
#
# The homelab image's counterpart to 20-packages-and-services.sh. Every test
# rewrites a throwaway copy to point at a sandbox context and stubs dnf5,
# systemctl and sleep. Nothing here is about the workstation image: the
# assertions that matter most are the ones about what this phase must NOT do,
# because the failure mode of a server image that grew a desktop is silent.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
BUILD_SRC="${REPO_ROOT}/build/20-server-base.sh"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/20-server.${BATS_TEST_NUMBER:-0}.$$"
	CTX="${TEST_ROOT}/ctx"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	SCRIPT="${TEST_ROOT}/20-server-base.sh"

	DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
	SYSTEMCTL_LOG="${TEST_ROOT}/logs/systemctl.log"
	SLEEP_LOG="${TEST_ROOT}/logs/sleep.log"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs" "${CTX}/build" \
		"${CTX}/etc/yum.repos.d" "${CTX}/etc/fail2ban/jail.d"

	cp "${REPO_ROOT}/build/copr-helpers.sh" "${CTX}/build/copr-helpers.sh"
	cp "${REPO_ROOT}/build/dnf5-retry.sh" "${CTX}/build/dnf5-retry.sh"

	# Every path the script writes outside its sandbox is redirected: /ctx for the
	# helper, /etc/yum.repos.d for the package factory, /etc/fail2ban for the jail.
	# On an immutable host the un-rewritten paths are read-only and every test in
	# this file would die on a write error instead of an assertion failure.
	sed -e "s#/ctx/#${CTX}/#g" \
		-e "s#/etc/yum.repos.d/#${CTX}/etc/yum.repos.d/#g" \
		-e "s#/etc/fail2ban/#${CTX}/etc/fail2ban/#g" \
		"${BUILD_SRC}" >"${SCRIPT}"

	# utah.repo ships enabled=1 because that is how the Containerfile leaves it
	# and the phase exists to close it.
	printf '[utah-packages]\nenabled=1\n' >"${CTX}/etc/yum.repos.d/utah.repo"

	export PATH="${STUB_BIN}:${PATH}"
	export DNF5_LOG SYSTEMCTL_LOG SLEEP_LOG
	export DNF5_RETRY_ATTEMPTS=1

	for tool in dnf5 systemctl; do
		local log_var
		log_var="$(printf '%s' "${tool}" | tr '[:lower:]' '[:upper:]')_LOG"
		cat >"${STUB_BIN}/${tool}" <<EOF
#!/usr/bin/bash
printf '%s\n' "\$*" >> "\${${log_var}}"
exit 0
EOF
		chmod +x "${STUB_BIN}/${tool}"
	done

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

@test "20-server-base: sandbox rewrite left no writes to the host filesystem" {
	# Guards the rewrites in setup(). If a path changes the sed stops matching and
	# the suite would exec the real package provider or write to the host's
	# yum.repos.d and fail2ban trees.
	local unguarded
	for unguarded in /ctx/ /etc/yum.repos.d/ /etc/fail2ban/; do
		run grep -nE "(^|[^-[:alnum:].])${unguarded}" "${SCRIPT}"
		[ "$status" -ne 0 ] || {
			echo "${SCRIPT} still writes to ${unguarded}" >&2
			return 1
		}
	done

	grep -q "source ${CTX}/build/copr-helpers.sh" "${SCRIPT}"
}

@test "20-server-base: completes successfully" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
}

@test "20-server-base: installs tailscale from Fedora proper, not a repository" {
	# No third-party repo: tailscale is in Fedora 44 proper, and a repository
	# would be one more thing live on every node in the cluster that
	# 90-cleanup.sh does not close.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'install -y tailscale' "${DNF5_LOG}"
	run grep -cE 'enablerepo|copr enable' "${DNF5_LOG}"
	[ "$output" -eq 0 ]
}

@test "20-server-base: installs fail2ban from Fedora proper" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -q 'fail2ban' "${DNF5_LOG}"
}

@test "20-server-base: enables fail2ban and the firewall it bans through" {
	# firewalld is not optional next to fail2ban: fail2ban writes a drop-in into
	# /etc/firewalld/direct.d/ and firewalld is what reads it. With firewalld
	# stopped, fail2ban bans nothing while appearing to work, which is the most
	# common way an install ends up decorative.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'enable firewalld.service' "${SYSTEMCTL_LOG}"
}

@test "20-server-base: ships an enabled sshd jail with sane thresholds" {
	# fail2ban ships an sshd jail that is present but disabled, because it
	# cannot know what else is listening. Left disabled, fail2ban runs and bans
	# nothing at all.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	jail="${CTX}/etc/fail2ban/jail.d/sshd.local"
	[ -f "${jail}" ]
	grep -qE '^enabled[[:space:]]*=[[:space:]]*true' "${jail}"

	# maxretry is asserted because it is the value that starts banning people who
	# mistype a password. Anything stricter is a support ticket.
	grep -qE '^maxretry[[:space:]]*=[[:space:]]*5$' "${jail}"
}

@test "20-server-base: writes the jail to jail.d, never the managed fail2ban.d" {
	# jail.d is the operator's directory. fail2ban.d is replaced wholesale by the
	# package on upgrade, so a config shipped there is a config that silently
	# reverts on the next system update -- and a node whose sshd jail reverted to
	# disabled is a node nobody was warned about.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[ ! -e "${CTX}/etc/fail2ban/fail2ban.d/sshd.local" ]
	[ -e "${CTX}/etc/fail2ban/jail.d/sshd.local" ]
}

@test "20-server-base: does not enable tailscaled or any uupd timer" {
	# Both are enabled nowhere on purpose, for two different reasons:
	#
	#   tailscaled   starts and holds no auth key until a person runs
	#                `tailscale up`. Enabling it at build time ships a daemon that
	#                cannot do anything.
	#   uupd.timer   applies updates and reboots. Every node in the cluster runs
	#                it, so all of them reboot at once and the cluster loses
	#                quorum. Rolling a cluster is an operator's deliberate,
	#                one-node-at-a-time job.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	run grep -cE 'tailscaled' "${SYSTEMCTL_LOG}"
	[ "$output" -eq 0 ]
	run grep -cE 'uupd' "${SYSTEMCTL_LOG}"
	[ "$output" -eq 0 ]
}

@test "20-server-base: installs no display manager, compositor or terminal" {
	# The whole reason this phase exists rather than the workstation's. A server
	# image that grew a login screen has gained an attack surface with no user
	# and nothing to log into.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	local desktop
	for desktop in gdm sddm ly mangowm hyprland ghostty voxtype; do
		run grep -cE "(^|[[:space:]])${desktop}([[:space:]]|$)" "${DNF5_LOG}"
		[ "$output" -eq 0 ] || {
			echo "${desktop} was requested by the server base phase" >&2
			return 1
		}
	done
}

@test "20-server-base: enables no service outside its own set" {
	# Boundary guard. 20-packages-and-services.sh is the workstation phase and
	# enables its own services; a change here must not quietly start reaching
	# into it.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[ "$(grep -c '^enable ' "${SYSTEMCTL_LOG}")" -eq 2 ]
}

@test "20-server-base: closes the Utah package factory before finishing" {
	# The factory's file:///etc/utah-packages baseurl only exists while the bind
	# mount does. This phase is the last thing in the homelab build that runs
	# dnf5, so this is the last point at which it can be closed without leaving a
	# window. 90-cleanup.sh closes it too.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[[ "$output" == *"utah-packages: enabled=0"* ]]
	run grep -cE '^enabled=1' "${CTX}/etc/yum.repos.d/utah.repo"
	[ "$output" -eq 0 ]
}

@test "20-server-base: fails when the package factory is missing from the context" {
	# Guarded rather than skipped: a live repository whose baseurl will not resolve
	# is worse than a failed build.
	rm -f "${CTX}/etc/yum.repos.d/utah.repo"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"utah.repo is missing"* ]]
}

@test "20-server-base: restores default glob behaviour before finishing" {
	cat >>"${SCRIPT}" <<'EOF'
shopt -q nullglob || echo "NULLGLOB_OFF"
EOF
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]
	[[ "$output" == *"NULLGLOB_OFF"* ]]
}