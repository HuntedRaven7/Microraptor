#!/usr/bin/env bats
# Unit tests for build/90-cleanup.sh.
#
# The script honours CLEAN_ROOT as a filesystem prefix, so every destructive
# operation runs against a sandbox directory instead of the host. dnf5,
# systemctl and mountpoint are stubbed on PATH.
#
# Run with: bats tests/template/90-cleanup_test.bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
CLEANUP_SRC="${SCRIPT_DIR}/../../build/90-cleanup.sh"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/90-cleanup.${BATS_TEST_NUMBER:-0}.$$"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
	SYSTEMCTL_LOG="${TEST_ROOT}/logs/systemctl.log"
	SANDBOX="${TEST_ROOT}/root"
	REPOS_DIR="${SANDBOX}/etc/yum.repos.d"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs"

	# Minimal filesystem layout the script expects to operate on.
	mkdir -p "${SANDBOX}/usr/lib/systemd/system"
	mkdir -p "${REPOS_DIR}"
	mkdir -p "${SANDBOX}/var/cache/libdnf5"
	mkdir -p "${SANDBOX}/var/cache/rpm-ostree"
	mkdir -p "${SANDBOX}/var/cache/dnf"
	mkdir -p "${SANDBOX}/var/log"
	mkdir -p "${SANDBOX}/tmp/leftover"
	mkdir -p "${SANDBOX}/boot/efi"
	mkdir -p "${SANDBOX}/run/dnf"
	touch "${SANDBOX}/usr/lib/systemd/system/flatpak-add-fedora-repos.service"
	touch "${SANDBOX}/.gitkeep"
	touch "${SANDBOX}/run/dnf/state"

	# One repository file per shape the script disables, plus the build-time
	# Fedora and Terra repos it must close.
	printf '[copr]\nenabled=1\n' \
		>"${REPOS_DIR}/_copr:copr.fedorainfracloud.org:ublue-os:packages.repo"
	printf '[rpmfusion]\nenabled=1\n' >"${REPOS_DIR}/rpmfusion-free.repo"
	printf '[multimedia]\nenabled=1\n' >"${REPOS_DIR}/fedora-multimedia.repo"
	printf '[fedora]\nenabled=1\n' >"${REPOS_DIR}/fedora.repo"
	printf '[terra]\nenabled=1\n' >"${REPOS_DIR}/terra.repo"

	export PATH="${STUB_BIN}:${PATH}"
	export CLEAN_ROOT="${SANDBOX}"
	export DNF5_LOG SYSTEMCTL_LOG

	cat >"${STUB_BIN}/dnf5" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${DNF5_LOG}"
exit 0
EOF
	chmod +x "${STUB_BIN}/dnf5"

	cat >"${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
exit 0
EOF
	chmod +x "${STUB_BIN}/systemctl"

	# mountpoint(1) is not meaningful inside the sandbox; default to "not a
	# mountpoint" so the script takes its normal removal path.
	cat >"${STUB_BIN}/mountpoint" <<'EOF'
#!/usr/bin/bash
exit 1
EOF
	chmod +x "${STUB_BIN}/mountpoint"
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

run_cleanup() {
	run bash "${CLEANUP_SRC}"
}

@test "90-cleanup: completes successfully against a sandbox root" {
	run_cleanup
	[ "$status" -eq 0 ]
}

@test "90-cleanup: emits GitHub Actions group markers" {
	run_cleanup
	[ "$status" -eq 0 ]
	[[ "$output" == *"::group:: Finalise package repositories"* ]]
	[[ "$output" == *"::group:: Finalise Flatpak sources"* ]]
	[[ "$output" == *"::group:: Prune build artifacts"* ]]
	[[ "$output" == *"::endgroup::"* ]]
}

@test "90-cleanup: restores dnf5 upstream defaults and clears versionlock" {
	run_cleanup
	[ "$status" -eq 0 ]

	mapfile -t calls <"${DNF5_LOG}"
	[ "${#calls[@]}" -eq 2 ]
	[ "${calls[0]}" = "config-manager setopt keepcache=0" ]
	[ "${calls[1]}" = "versionlock clear" ]
}

@test "90-cleanup: disables and masks the fedora flatpak service and the base updater" {
	run_cleanup
	[ "$status" -eq 0 ]

	# Three calls, in order: disable and mask the Flatpak remote, then the base
	# updater. The Flatpak pair is behind a list-unit-files guard, so it only
	# appears when the stub reports the unit.
	mapfile -t calls <"${SYSTEMCTL_LOG}"
	[ "${#calls[@]}" -eq 4 ]
	[ "${calls[0]}" = "list-unit-files flatpak-add-fedora-repos.service" ]
	[ "${calls[1]}" = "disable flatpak-add-fedora-repos.service" ]
	[ "${calls[2]}" = "mask flatpak-add-fedora-repos.service" ]
	[ "${calls[3]}" = "disable rpm-ostreed-automatic.timer" ]
}

@test "90-cleanup: tolerates a base that ships no flatpak-add-fedora-repos unit" {
	# A base with no flatpak package has no such unit, and `systemctl disable`
	# exits non-zero on a missing unit, which under `set -e` would fail the
	# build. The guard must let the phase finish and still stop the updater.
	systemctl() {
		case "$*" in
			*list-unit-files*) return 1 ;;
		esac
		printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
		return 0
	}
	export -f systemctl 2>/dev/null || true
	cat >"${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/bash
case "$*" in
	*list-unit-files*) exit 1 ;;
esac
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
exit 0
EOF
	chmod +x "${STUB_BIN}/systemctl"

	run_cleanup
	[ "$status" -eq 0 ]

	# No disable or mask was attempted against a unit that does not exist.
	run grep -c 'flatpak-add-fedora-repos' "${SYSTEMCTL_LOG}"
	[ "$output" -eq 0 ]
	# The base updater is still stopped.
	grep -qx 'disable rpm-ostreed-automatic.timer' "${SYSTEMCTL_LOG}"
	# And the unit file, if any, is untouched rather than half-handled.
	[ -f "${SANDBOX}/usr/lib/systemd/system/flatpak-add-fedora-repos.service" ]
}

@test "90-cleanup: removes the flatpak-add-fedora-repos unit file" {
	[ -f "${SANDBOX}/usr/lib/systemd/system/flatpak-add-fedora-repos.service" ]

	run_cleanup
	[ "$status" -eq 0 ]
	[ ! -e "${SANDBOX}/usr/lib/systemd/system/flatpak-add-fedora-repos.service" ]
}

@test "90-cleanup: disables every third-party repository, and the build-time Fedora one" {
	run_cleanup
	[ "$status" -eq 0 ]

	grep -q '^enabled=0' "${REPOS_DIR}/_copr:copr.fedorainfracloud.org:ublue-os:packages.repo"
	grep -q '^enabled=0' "${REPOS_DIR}/rpmfusion-free.repo"
	grep -q '^enabled=0' "${REPOS_DIR}/fedora-multimedia.repo"
	# Both are enabled at build time -- a base with no repository of its own
	# needs fedora to install anything, and ghostty only exists in Terra -- and
	# closed here, so an installed system resolves only the base's own rebuilt
	# RPMs.
	grep -q '^enabled=0' "${REPOS_DIR}/fedora.repo"
	grep -q '^enabled=0' "${REPOS_DIR}/terra.repo"
}

@test "90-cleanup: closes the unsigned repository too" {
	# Terra ships no usable GPG key, so its packages are unverified by
	# construction. That is precisely why it must not be left enabled on an
	# installed system: there is no signature for the container trust policy to
	# check, and the image would silently pull from it forever.
	run_cleanup
	[ "$status" -eq 0 ]

	run grep -q '^enabled=1' "${REPOS_DIR}/terra.repo"
	[ "$status" -ne 0 ]
}

@test "90-cleanup: closes every stanza in the build-time Fedora repository" {
	# packages/fedora.repo carries both fedora-44 and fedora-44-updates. A
	# build that closed only the first would leave the second live.
	printf '[fedora-44]\nenabled=1\nzchunk=false\n' \
		>"${REPOS_DIR}/fedora.repo"
	printf '\n[fedora-44-updates]\nenabled=1\n' >>"${REPOS_DIR}/fedora.repo"

	run_cleanup
	[ "$status" -eq 0 ]

	[ "$(grep -c '^enabled=0' "${REPOS_DIR}/fedora.repo")" -eq 2 ]
	run grep -q '^enabled=1' "${REPOS_DIR}/fedora.repo"
	[ "$status" -ne 0 ]
}

@test "90-cleanup: fails when the build-time Fedora repository is still enabled" {
	# Same contract as the third-party repositories, extended to Fedora: a
	# repository that must not ship cannot be quietly left live.
	printf '[fedora-44]\nenabled=1\n' >"${REPOS_DIR}/fedora.repo"

	cat >"${STUB_BIN}/sed" <<'EOF'
#!/usr/bin/bash
# Simulate a repository file the script cannot rewrite.
exit 1
EOF
	chmod +x "${STUB_BIN}/sed"

	run_cleanup
	[ "$status" -ne 0 ]
}

@test "90-cleanup: leaves an already-disabled third-party repository disabled" {
	printf '[copr]\nenabled=0\n' \
		>"${REPOS_DIR}/_copr:copr.fedorainfracloud.org:ublue-os:packages.repo"

	run_cleanup
	[ "$status" -eq 0 ]

	grep -q '^enabled=0' "${REPOS_DIR}/_copr:copr.fedorainfracloud.org:ublue-os:packages.repo"
}

@test "90-cleanup: fails the build when a third-party repository cannot be disabled" {
	# The build must never ship a live third-party repository, so a repository
	# the script cannot rewrite is a hard failure. sed -i needs a writable
	# directory rather than a writable file, and root bypasses permissions.
	[ "$(id -u)" -ne 0 ] || skip "file permissions do not apply to root"
	chmod 500 "${REPOS_DIR}"

	run_cleanup
	[ "$status" -ne 0 ]
	chmod 700 "${REPOS_DIR}"
}

@test "90-cleanup: removes the root .gitkeep placeholder" {
	run_cleanup
	[ "$status" -eq 0 ]
	[ ! -e "${SANDBOX}/.gitkeep" ]
}

@test "90-cleanup: removes /var subdirectories other than cache" {
	run_cleanup
	[ "$status" -eq 0 ]
	[ ! -e "${SANDBOX}/var/log" ]
	[ -d "${SANDBOX}/var/cache" ]
}

@test "90-cleanup: keeps libdnf5 and rpm-ostree cache dirs, drops the rest" {
	run_cleanup
	[ "$status" -eq 0 ]
	[ -d "${SANDBOX}/var/cache/libdnf5" ]
	[ -d "${SANDBOX}/var/cache/rpm-ostree" ]
	[ ! -e "${SANDBOX}/var/cache/dnf" ]
}

@test "90-cleanup: empties tmp and boot but keeps the directories" {
	run_cleanup
	[ "$status" -eq 0 ]
	[ -d "${SANDBOX}/tmp" ]
	[ -d "${SANDBOX}/boot" ]
	[ ! -e "${SANDBOX}/tmp/leftover" ]
	[ ! -e "${SANDBOX}/boot/efi" ]
}

@test "90-cleanup: creates tmp and boot when they are absent" {
	rm -rf "${SANDBOX}/tmp" "${SANDBOX}/boot"

	run_cleanup
	[ "$status" -eq 0 ]
	[ -d "${SANDBOX}/tmp" ]
	[ -d "${SANDBOX}/boot" ]
}

@test "90-cleanup: clears /run contents while keeping /run itself" {
	run_cleanup
	[ "$status" -eq 0 ]
	[ -d "${SANDBOX}/run" ]
	[ ! -e "${SANDBOX}/run/dnf" ]
}

@test "90-cleanup: skips mounted entries under tmp, boot and run" {
	mkdir -p "${SANDBOX}/run/mounted"
	touch "${SANDBOX}/run/mounted/keepme"
	mkdir -p "${SANDBOX}/tmp/mounted"

	cat >"${STUB_BIN}/mountpoint" <<EOF
#!/usr/bin/bash
# Treat only the two seeded paths as mountpoints.
case "\$2" in
  "${SANDBOX}/run/mounted"|"${SANDBOX}/tmp/mounted") exit 0 ;;
esac
exit 1
EOF
	chmod +x "${STUB_BIN}/mountpoint"

	run_cleanup
	[ "$status" -eq 0 ]
	[ -d "${SANDBOX}/run/mounted" ]
	[ -d "${SANDBOX}/tmp/mounted" ]
}

@test "90-cleanup: tolerates empty var cache directories" {
	rm -rf "${SANDBOX}/var/cache/libdnf5" "${SANDBOX}/var/cache/rpm-ostree" "${SANDBOX}/var/cache/dnf"

	run_cleanup
	[ "$status" -eq 0 ]
	[ -d "${SANDBOX}/var/cache" ]
}

@test "90-cleanup: is idempotent across repeated runs" {
	run_cleanup
	[ "$status" -eq 0 ]

	run_cleanup
	[ "$status" -eq 0 ]
}
