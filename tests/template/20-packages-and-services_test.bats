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
	CURL_LOG="${TEST_ROOT}/logs/curl.log"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs" "${CTX}/build" \
		"${CTX}/usr/lib/systemd" "${CTX}/etc/yum.repos.d"

	# The real helper library is sourced verbatim so a syntax break there fails
	# this suite too. dnf5-retry.sh is sourced by copr-helpers.sh relative to its
	# own location, so it has to sit beside it in the sandbox.
	cp "${REPO_ROOT}/build/copr-helpers.sh" "${CTX}/build/copr-helpers.sh"
	cp "${REPO_ROOT}/build/dnf5-retry.sh" "${CTX}/build/dnf5-retry.sh"

	# Every path the script writes outside its sandbox is redirected. It runs as
	# root in the image and writes to three places, only one of which is the build
	# context:
	#
	#   /ctx                 the build context, mounted by the Containerfile
	#   /usr/lib/systemd     logind.conf, for the lid-switch defaults
	#   /etc/yum.repos.d     utah.repo, flipped to enabled=0 when the package
	#                        factory is closed
	#
	# Only the first was redirected, so on a host with a read-only root -- an
	# immutable one, which is the sort of machine this suite is likely to be run
	# from -- every test in this file died on a sed error instead of an assertion
	# failure, and the two tests that assert on the repo file asserted against
	# whatever the host happened to have.
	sed -e "s#/ctx/#${CTX}/#g" \
		-e "s#/usr/lib/systemd/#${CTX}/usr/lib/systemd/#g" \
		-e "s#/etc/yum.repos.d/#${CTX}/etc/yum.repos.d/#g" \
		"${BUILD_SRC}" >"${SCRIPT}"

	# Seeded rather than created by the script, because the script does not create
	# them. logind.conf is only touched when it already exists; utah.repo is
	# required, and the script exits 1 rather than continue if it is missing, which
	# is the behaviour a base without the package factory should get.
	#
	# utah.repo ships enabled=1 because that is how the Containerfile leaves it and
	# the phase exists to close it -- a sandbox that started it disabled would let
	# the script pass without ever exercising the flip or the assertion after it.
	: >"${CTX}/usr/lib/systemd/logind.conf"
	printf '[utah-packages]\nenabled=1\n' >"${CTX}/etc/yum.repos.d/utah.repo"

	# The Voxtype group verifies the RPM it downloads against a digest pinned in
	# the script. The curl stub below writes this payload rather than 357 MB of
	# release asset, so the pinned digest is rewritten to match it. sha256sum is
	# NOT stubbed: the check itself is what these tests exist to exercise.
	VOXTYPE_STUB_PAYLOAD="${TEST_ROOT}/voxtype-stub.rpm"
	printf 'voxtype test payload\n' >"${VOXTYPE_STUB_PAYLOAD}"
	local stub_digest
	stub_digest="$(sha256sum "${VOXTYPE_STUB_PAYLOAD}" | cut -d' ' -f1)"
	sed -i "s/^voxtype_rpm_sha256=.*/voxtype_rpm_sha256=\"${stub_digest}\"/" "${SCRIPT}"

	export VOXTYPE_STUB_PAYLOAD

	export PATH="${STUB_BIN}:${PATH}"
	export DNF5_LOG SYSTEMCTL_LOG RSYNC_LOG SLEEP_LOG CURL_LOG
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

	# The Voxtype group is the only thing in this phase that uses the network
	# directly, and it is the only one whose integrity story the stub has to
	# preserve: it writes a payload whose real digest the script is then made to
	# check. CURL_FAIL flips it to a download that always 404s, so the retry loop
	# and its abort are testable without a slow fetch.
	cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG}"
if [ -n "${CURL_FAIL:-}" ]; then
	echo "curl: (22) The requested URL returned error: 404" >&2
	exit 22
fi
output=""
while [ "$#" -gt 0 ]; do
	if [ "$1" = "--output" ]; then
		output="$2"
	fi
	shift
done
[ -n "${output}" ] || exit 2
cp "${VOXTYPE_STUB_PAYLOAD}" "${output}"
EOF
	chmod +x "${STUB_BIN}/curl"
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

@test "20-packages-and-services: sandbox rewrite left no writes to the host filesystem" {
	# Guards the rewrites in setup(): if the script's paths change, the sed no
	# longer matches and the suite would exec the real package provider, or write
	# to the host's systemd and yum.repos.d trees.
	local unguarded
	for unguarded in /ctx/ /usr/lib/systemd/ /etc/yum.repos.d/; do
		run grep -nE "(^|[^-[:alnum:]])${unguarded}" "${SCRIPT}"
		[ "$status" -ne 0 ] || {
			echo "${SCRIPT} still writes to ${unguarded}" >&2
			return 1
		}
	done

	grep -q "source ${CTX}/build/copr-helpers.sh" "${SCRIPT}"
}

@test "20-packages-and-services: closes the Utah package factory at the end of the phase" {
	# utah.repo points at file:///etc/utah-packages, a bind mount that only exists
	# while this phase runs. The flip and the assertion after it are the only
	# reason a later dnf5 call does not fail to fetch its metadata, and the reason
	# the image does not ship a live repository whose baseurl is a path that will
	# not resolve.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	[[ "$output" == *"utah-packages: enabled=0"* ]]
	run grep -cE '^enabled=1' "${CTX}/etc/yum.repos.d/utah.repo"
	[ "$output" -eq 0 ]
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
	[[ "$output" == *"::group:: Install ly and Tailscale"* ]]
	[[ "$output" == *"::group:: Install Ghostty and MangoWM from Terra"* ]]
	[[ "$output" == *"::group:: Install Voxtype from its release RPM"* ]]
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
	# PipeWire and friends have to be named: neither the display manager nor
	# MangoWM depends on a sound server, and this base has no GNOME or Plasma
	# pulling one in. An installed system with no audio at all is the failure this
	# prevents.
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
	# ly and tailscale come from Fedora proper, not a third-party repository.
	# Asserting the repo-less call is the point: it is what stops a later edit
	# from quietly adding a repository for something Fedora already ships. ly in
	# particular looks like it would need a COPR, because upstream ships no RPM --
	# Fedora 44 packages it (ly-1.4.0-2.fc44 in F44 Updates) all the same.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'install -y ly tailscale' "${DNF5_LOG}"
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

@test "20-packages-and-services: installs Voxtype from a pinned URL, checked by digest" {
	# The one package in this image with no repository behind it: upstream ships a
	# release RPM and nothing a distro could repackage, so there is no repo
	# metadata and no GPG key to prove what the bytes are. A version in the URL and
	# a digest beside it are the whole integrity story, so both are asserted here.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# The version appears in the fetched URL, so a bump cannot silently leave the
	# old RPM installed under a new digest.
	grep -qF 'releases/download/v1.1.0/voxtype-1.1.0-1.x86_64.rpm' "${CURL_LOG}"
	# And it is handed to dnf5 as a local file from the temp directory the
	# Containerfile mounts as tmpfs, not fetched by dnf5 from the URL itself.
	grep -q 'install -y --nogpgcheck /tmp/' "${DNF5_LOG}"
	grep -q 'voxtype-1.1.0-1.x86_64.rpm' "${DNF5_LOG}"
}

@test "20-packages-and-services: installs curl and wtype alongside Voxtype" {
	# curl is the tool that fetches the RPM, so it cannot be left to the RPM's own
	# dependency on it -- that is circular, and on a base without curl the run
	# fails on a missing package instead of installing one.
	#
	# wtype is the Wayland typing backend. Upstream ranks it above the
	# dotool -> ydotool -> clipboard chain, and this image is a Wayland session,
	# so without it dictation falls all the way through to the clipboard.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'install -y curl wtype' "${DNF5_LOG}"
}

@test "20-packages-and-services: --nogpgcheck replaces an absent signature, not a check" {
	# The RPM is unsigned -- `rpm -Kv` reports "Signature: (none)" -- and upstream's
	# SHA256SUMS.txt has no line for it. So there is no key to import and nothing
	# for gpgcheck to verify, and --nogpgcheck is what says so out loud. It is only
	# safe because the digest check runs first, which the next test pins down.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -q -- '--nogpgcheck' "${DNF5_LOG}"
	# And nobody reaches for a key to check it against, because there is no key
	# file to add. The patterns are chosen not to match --nogpgcheck itself:
	# `gpgcheck` alone is a substring of it, and `gpgcheck=` and `--gpgcheck` are
	# not, so this fails only on a real attempt to configure or import one.
	run grep -cE 'rpm --import|gpgcheck=|--gpgcheck' "${SCRIPT}"
	[ "$output" -eq 0 ]
}

@test "20-packages-and-services: a Voxtype digest mismatch fails the build before dnf5 sees the file" {
	# The order is the whole point. dnf5 unpacks the payload as it installs, so a
	# digest checked afterwards would be reporting on bytes already written to the
	# image, and a build that caught the mismatch would still have shipped them.
	# sha256sum is the real one, so this is the real check failing.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	sed -i 's/^voxtype_rpm_sha256=.*/voxtype_rpm_sha256="0000000000000000000000000000000000000000000000000000000000000000"/' \
		"${SCRIPT}"
	rm -f "${DNF5_LOG}"
	run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not match the pinned digest"* ]]

	# Never reached the installer. The one call that did happen is the curl/wtype
	# transaction, which runs first by design.
	grep -qx 'install -y curl wtype' "${DNF5_LOG}"
	run grep -c 'voxtype' "${DNF5_LOG}"
	[ "$output" -eq 0 ]
}

@test "20-packages-and-services: retries a failed Voxtype download then gives up" {
	# The release asset sits behind a 302 to a CDN host that intermittently 404s,
	# which is the same failure dnf5_retry exists for. curl's own --retry does not
	# cover it: it retries one request against one URL, and there is no second host
	# to fail over to. So the whole fetch is looped.
	CURL_FAIL=1 run bash "${SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not fetch"* ]]

	# Three attempts, then it stops rather than looping.
	[ "$(grep -c 'voxtype fetch failed' <<<"${output}")" -eq 3 ]
	# And a fetch that never landed is never handed to dnf5.
	run grep -c 'voxtype' "${DNF5_LOG}"
	[ "$output" -eq 0 ]
}

@test "20-packages-and-services: does not enable the Voxtype user service at build time" {
	# voxtype.service is WantedBy=graphical-session.target and starts the daemon,
	# which fails immediately without a model. Models are a per-machine download
	# that `voxtype setup --download` fetches on the user's own hardware, so
	# enabling the unit in the image ships a service that cannot start. The README
	# carries the enable step instead.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	run grep -c 'voxtype' "${SYSTEMCTL_LOG}"
	[ "$output" -eq 0 ]
}

@test "20-packages-and-services: enables the display manager and tailscaled" {
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qx 'enable ly@tty1.service' "${SYSTEMCTL_LOG}"
	grep -qx 'enable tailscaled.service' "${SYSTEMCTL_LOG}"
}

@test "20-packages-and-services: enables a ly instance, never a bare ly.service" {
	# ly ships ly@.service as a template and no ly.service at all, so enabling the
	# bare name fails at build time with "unit file does not exist" rather than
	# shipping a machine with no login screen. The instance also has to be named:
	# the template sets DefaultInstance=tty2, so an unnamed enable would put the
	# login on tty2 and leave tty1 running a getty.
	#
	# Asserted as a pattern rather than a plain grep -v so it also catches an edit
	# that enables the instance *and* something else ly-shaped -- both units at
	# once would leave two TUI logins fighting over the VT.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	run grep -cE '^enable ly(@[a-z0-9]+)?\.service$' "${SYSTEMCTL_LOG}"
	[ "$output" -eq 1 ]
	run grep -qx 'enable ly.service' "${SYSTEMCTL_LOG}"
	[ "$status" -ne 0 ]
}

@test "20-packages-and-services: installs and enables no GDM" {
	# The swap off GDM is the reason the display manager group exists. Two
	# separate failure modes, so two assertions: the RPM still being requested
	# would put GNOME's session stack back in the image, and the unit still being
	# enabled would leave two display managers on a machine.
	#
	# disable_unit gdm.service is expected and is not what this guards -- it is a
	# no-op on a base that does not ship gdm, and it is what the next test covers.
	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	run grep -cE '(^|[[:space:]])gdm([[:space:]]|$)' "${DNF5_LOG}"
	[ "$output" -eq 0 ]
	run grep -cx 'enable gdm.service' "${SYSTEMCTL_LOG}"
	[ "$status" -ne 0 ]
}

@test "20-packages-and-services: disables gdm rather than failing when it is absent" {
	# gdm is no longer named in any transaction, so on this base the unit does not
	# exist. The guarded helper is what keeps that a no-op instead of a build
	# failure: unit_exists returns false, the disable is skipped, and the phase
	# carries on. It is also the only reason the swap is safe on a base that does
	# still ship gdm, where the disable has to actually happen.
	#
	# systemctl cat is what unit_exists tests, and the stub above answers every
	# `systemctl` call with success -- so this exercises the guard against the
	# stub reporting the unit as absent, which is the branch the real base takes.
	cat >"${STUB_BIN}/systemctl" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${SYSTEMCTL_LOG}"
# Only ly's units exist, matching a base that does not ship gdm.
if [ "$1" = "cat" ]; then
	case "$2" in
	ly@*.service) exit 0 ;;
	*) exit 1 ;;
	esac
fi
exit 0
EOF
	chmod +x "${STUB_BIN}/systemctl"

	run bash "${SCRIPT}"
	[ "$status" -eq 0 ]

	# The disable was attempted, and nothing else went wrong because the unit was
	# not there -- the phase still closed the Utah factory at the end.
	grep -qx 'cat gdm.service' "${SYSTEMCTL_LOG}"
	[[ "$output" == *"utah-packages: enabled=0"* ]]
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
	for unit in ly@tty1.service tailscaled.service uupd.timer uupd-resume.timer; do
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
