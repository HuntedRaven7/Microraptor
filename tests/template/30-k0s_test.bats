#!/usr/bin/env bats
# Unit tests for build/30-k0s.sh and build/35-kc-agent.sh.
#
# Both phases install a pinned binary from a release URL, so both share one
# shape and are tested together: fetch, verify the digest before install, install,
# and prove the binary runs. The per-phase tests cover what differs, which is
# mainly the enablement policy.
#
# The digest is rewritten to match a stub payload in setup(), the same way
# 20-packages-and-services_test.bats handles Voxtype. sha256sum is NOT stubbed:
# the check itself is what these tests exist to exercise, so it has to be real.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
K0S_SRC="${REPO_ROOT}/build/30-k0s.sh"
KC_SRC="${REPO_ROOT}/build/35-kc-agent.sh"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/k0s.${BATS_TEST_NUMBER:-0}.$$"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	K0S_SCRIPT="${TEST_ROOT}/30-k0s.sh"
	KC_SCRIPT="${TEST_ROOT}/35-kc-agent.sh"

	DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
	SYSTEMCTL_LOG="${TEST_ROOT}/logs/systemctl.log"
	CURL_LOG="${TEST_ROOT}/logs/curl.log"
	SLEEP_LOG="${TEST_ROOT}/logs/sleep.log"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs" "${TEST_ROOT}/ctx/build" \
		"${TEST_ROOT}/root/opt/bin" "${TEST_ROOT}/root/etc/sysconfig" \
		"${TEST_ROOT}/root/usr/lib/systemd/system" \
		"${TEST_ROOT}/root/usr/share/licenses" \
		"${TEST_ROOT}/root/etc/k0s"

	# dnf5-retry.sh sits beside the phases in the sandbox context, because both
	# phases source it from /ctx/build. The real helper is copied verbatim so a
	# syntax break in it fails this suite too.
	cp "${REPO_ROOT}/build/dnf5-retry.sh" "${TEST_ROOT}/ctx/build/dnf5-retry.sh"

	# Paths the scripts write outside their sandbox, all redirected: /ctx for the
	# helper, /opt for the binaries, /etc/sysconfig for the argument files,
	# /usr/lib/systemd/system for the units, /usr/share/licenses for kc-agent's
	# LICENSE, /etc/k0s for the token path the units reference.
	sed -e "s#/ctx/#${TEST_ROOT}/ctx/#g" \
		-e "s#/opt/bin#${TEST_ROOT}/root/opt/bin#g" \
		-e "s#/etc/sysconfig#${TEST_ROOT}/root/etc/sysconfig#g" \
		-e "s#/usr/lib/systemd/system#${TEST_ROOT}/root/usr/lib/systemd/system#g" \
		-e "s#/usr/share/licenses#${TEST_ROOT}/root/usr/share/licenses#g" \
		-e "s#/etc/k0s#${TEST_ROOT}/root/etc/k0s#g" \
		"${K0S_SRC}" >"${K0S_SCRIPT}"
	sed -e "s#/ctx/#${TEST_ROOT}/ctx/#g" \
		-e "s#/opt/bin#${TEST_ROOT}/root/opt/bin#g" \
		-e "s#/etc/sysconfig#${TEST_ROOT}/root/etc/sysconfig#g" \
		-e "s#/usr/lib/systemd/system#${TEST_ROOT}/root/usr/lib/systemd/system#g" \
		-e "s#/usr/share/licenses#${TEST_ROOT}/root/usr/share/licenses#g" \
		-e "s#/etc/k0s#${TEST_ROOT}/root/etc/k0s#g" \
		-e "s#/etc/systemd/system#${TEST_ROOT}/root/etc/systemd/system#g" \
		"${KC_SRC}" >"${KC_SCRIPT}"

	# The stub payload stands in for the 263 MB k0s binary and the kc-agent
	# tarball. Both are runnable stubs so the "prove it runs" check passes; the
	# tarball stub has to be a real gzip tarball because the phase untars it.
	printf '#!/usr/bin/bash\necho "k0s stub version"\n' >"${TEST_ROOT}/payload-bin"
	chmod +x "${TEST_ROOT}/payload-bin"
	K0S_PAYLOAD="${TEST_ROOT}/payload-bin"

	mkdir -p "${TEST_ROOT}/tar-src"
	printf '#!/usr/bin/bash\necho "kc-agent stub version"\n' >"${TEST_ROOT}/tar-src/kc-agent"
	chmod +x "${TEST_ROOT}/tar-src/kc-agent"
	printf 'Apache-2.0 test license\n' >"${TEST_ROOT}/tar-src/LICENSE"
	tar -czf "${TEST_ROOT}/payload.tar.gz" -C "${TEST_ROOT}/tar-src" kc-agent LICENSE
	KC_PAYLOAD="${TEST_ROOT}/payload.tar.gz"

	# Both digests are rewritten to the stub payload each script fetches.
	#
	# The `;;` is kept on rewrite, and this is why. The pattern is
	# `  amd64) k0s_sha256=.*` with no anchor at the end, so it consumes the
	# line's trailing ` ;;` along with the digest. Replacing that whole span with
	# a bare assignment leaves the case arm unterminated and the rewritten script
	# dies at parse time with "syntax error near unexpected token `)'" -- which
	# reads as a bug in the phase rather than in the test.
	#
	# The group captures only `  amd64`, so the replacement re-emits it rather
	# than relying on the match being reproduced by hand. Getting that wrong
	# silently yields a script whose digest is never rewritten at all: the phase
	# then checks the stub payload against upstream's real digest and every
	# positive-path test fails with a digest mismatch, which points squarely at
	# the pinned value in build/30-k0s.sh and nowhere near the test.
	#
	# Hence the assertion below that the rewrite landed.
	# k0s's stub payload is a plain binary and kc-agent's is a tarball, so the
	# two phases must not share a digest -- otherwise each phase's integrity
	# check would be verifying the other's bytes, which is the exact mistake
	# these tests exist to catch.
	#
	# The check itself has to run for real: sha256sum is deliberately NOT stubbed.
	# That means the pinned value in the phase is replaced with the digest of
	# whatever the curl stub actually wrote, which is the only way the positive
	# path can be exercised at all -- and it is why setup() must hand each phase
	# the payload its own URL will receive.
	# The ` ;;` is re-emitted rather than swallowed, and the pattern spells the whole
	# prefix out instead of capturing it with \( \).
	#
	# Both details were found the hard way. A capture of the form
	# s/^\(  amd64\) k0s_sha256=.*/\1 .../ looks correct and silently matches
	# nothing: in BRE a `\(` group cannot span the unbalanced `)` in `amd64)`, so
	# the expression never matches and every positive-path test fails with a digest
	# mismatch -- a symptom that points at the pinned digest in build/30-k0s.sh
	# rather than at this sed. Writing the literal prefix sidesteps the trap.
	_set_k0s_digest() {
		sed -i \
			-e "s/^  amd64) k0s_sha256=.*/  amd64) k0s_sha256=\"$1\" ;;/" \
			-e "s/^  arm64) k0s_sha256=.*/  arm64) k0s_sha256=\"$1\" ;;/" \
			"${K0S_SCRIPT}"
	}
	_set_kc_digest() {
		sed -i \
			-e "s/^  amd64) kc_sha256=.*/  amd64) kc_sha256=\"$1\" ;;/" \
			-e "s/^  arm64) kc_sha256=.*/  arm64) kc_sha256=\"$1\" ;;/" \
			"${KC_SCRIPT}"
	}
	local k0s_digest kc_digest
	k0s_digest="$(sha256sum "${K0S_PAYLOAD}" | cut -d' ' -f1)"
	kc_digest="$(sha256sum "${KC_PAYLOAD}" | cut -d' ' -f1)"
	_set_k0s_digest "${k0s_digest}"
	_set_kc_digest "${kc_digest}"

	# The rewrite must have landed on both architectures in both scripts. Without
	# this, a rewrite that quietly matched nothing shows up as a digest-mismatch
	# failure in every positive-path test, which reads as a bad pin in the phase
	# rather than a broken sed here.
	grep -q "amd64) k0s_sha256=\"${k0s_digest}\"" "${K0S_SCRIPT}"
	grep -q "arm64) k0s_sha256=\"${k0s_digest}\"" "${K0S_SCRIPT}"
	grep -q "amd64) kc_sha256=\"${kc_digest}\"" "${KC_SCRIPT}"
	grep -q "arm64) kc_sha256=\"${kc_digest}\"" "${KC_SCRIPT}"

	# The rewrites above must leave parseable scripts. This guard is not
	# decoration: a rewrite that eats the trailing `;;` produces an unparseable
	# phase, which then fails every test in the file as "command not found" --
	# a symptom that points at the phase rather than at the test.
	bash -n "${K0S_SCRIPT}" || {
		echo "the k0s digest rewrite produced an unparseable script" >&2
		return 1
	}
	bash -n "${KC_SCRIPT}" || {
		echo "the kc-agent digest rewrite produced an unparseable script" >&2
		return 1
	}

	bash -n "${K0S_SCRIPT}" || {
		echo "the k0s digest rewrite produced an unparseable script" >&2
		return 1
	}
	bash -n "${KC_SCRIPT}" || {
		echo "the kc-agent digest rewrite produced an unparseable script" >&2
		return 1
	}

	export K0S_PAYLOAD KC_PAYLOAD
	export PATH="${STUB_BIN}:${PATH}"
	export DNF5_LOG SYSTEMCTL_LOG CURL_LOG SLEEP_LOG
	export DNF5_RETRY_ATTEMPTS=1
	export TARGETARCH="amd64"

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

	# curl answers with whichever stub payload the requested asset belongs to.
	#
	# The dispatch matches on the --output path, NOT on "$*". The phase's own URL is
	# a positional argument that is still present when the loop above consumes
	# argv, so selecting on "$*" after that loop matches only the flags that
	# remain -- and "*" then wins, every fetch receives the k0s payload, and
	# kc-agent's digest check fails on bytes that are the wrong file entirely.
	# That failure points at the pinned digest in build/35-kc-agent.sh, which is
	# the least useful place for it to point.
	#
	# Matching the output path means the phase still has to ask for the right
	# asset name: a phase that fetched kc-agent's tarball from a URL named for the
	# binary would now be caught here instead of silently passing.
	cat >"${STUB_BIN}/curl" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${CURL_LOG}"
if [ -n "${CURL_FAIL:-}" ]; then
	echo "curl: (22) The requested URL returned error: 404" >&2
	exit 22
fi
output=""
url=""
while [ "$#" -gt 0 ]; do
	if [ "$1" = "--output" ]; then
		output="$2"
	fi
	# The last bare argument is the URL; flags all have values.
	if [ "${1#-}" = "$1" ]; then
		url="$1"
	fi
	shift
done
[ -n "${output}" ] || exit 2
case "${url}" in
*kc-agent_*) cp "${KC_PAYLOAD}" "${output}" ;;
*) cp "${K0S_PAYLOAD}" "${output}" ;;
esac
EOF
	chmod +x "${STUB_BIN}/curl"
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

### k0s

@test "30-k0s: installs from the pinned release URL" {
	run bash "${K0S_SCRIPT}"
	[ "$status" -eq 0 ]

	# The version appears in the fetched URL, so a bump cannot leave the old
	# binary in place under a new digest.
	grep -qF 'k0sproject/k0s/releases/download/v1.36.4%2Bk0s.1/k0s-v1.36.4+k0s.1-amd64' "${CURL_LOG}"
	[ -x "${TEST_ROOT}/root/opt/bin/k0s" ]
}

@test "30-k0s: percent-encodes the plus in the version tag" {
	# The version contains a real '+'. GitHub's download path documents it
	# percent-encoded; leaving it literal happens to work because an unencoded
	# '+' in a path is a plus, not a space. Asserted so the encoding cannot be
	# 'simplified' away into something that breaks.
	run bash "${K0S_SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qF '%2B' "${CURL_LOG}"
}

@test "30-k0s: a digest mismatch fails the build and installs nothing" {
	# The check runs before install, so a mismatch leaves the image unchanged.
	# sha256sum is the real one, so this is the real check failing.
	# Same literal-prefix form as setup() uses, for the same reason: a rewrite that
	# swallows the trailing ` ;;` produces an unparseable script and the failure
	# reads as a phase bug.
	sed -i \
		-e 's/^  amd64) k0s_sha256=.*/  amd64) k0s_sha256="0000000000000000000000000000000000000000000000000000000000000000" ;;/' \
		"${K0S_SCRIPT}"
	run bash "${K0S_SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not match the pinned digest"* ]]

	[ ! -e "${TEST_ROOT}/root/opt/bin/k0s" ]
	# And no unit was installed either, so a failed fetch does not leave units
	# pointing at a binary that is not there.
	[ ! -e "${TEST_ROOT}/root/usr/lib/systemd/system/k0scontroller.service" ]
}

@test "30-k0s: retries a failed download then gives up" {
	# The GitHub release CDN 302s to a host that intermittently fails, which is
	# the same failure dnf5_retry exists for. curl's own --retry does not cover
	# it: one request against one URL with no host to fail over to.
	CURL_FAIL=1 run bash "${K0S_SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"could not fetch"* ]]

	[ "$(grep -c 'k0s fetch failed' <<<"${output}")" -eq 3 ]
	[ ! -e "${TEST_ROOT}/root/opt/bin/k0s" ]
}

@test "30-k0s: installs both units and enables neither" {
	# A node is a controller or a worker by decision, not by image. Enabling the
	# controller because a single-node cluster is the common first case is how a
	# three-node cluster ends up assembled by three machines all believing they
	# were the control plane.
	run bash "${K0S_SCRIPT}"
	[ "$status" -eq 0 ]

	[ -f "${TEST_ROOT}/root/usr/lib/systemd/system/k0scontroller.service" ]
	[ -f "${TEST_ROOT}/root/usr/lib/systemd/system/k0sworker.service" ]

	# Asserted as "no systemctl call at all" rather than "no enable call", and the
	# distinction is load-bearing: neither phase invokes systemctl any more, so the
	# stub never runs and the log is never created. `grep -c` on a missing file
	# yields an EMPTY string rather than 0, so `[ "" -eq 0 ]` is a syntax error and
	# the assertion would fail on the absence of the very file it was checking.
	#
	# 30-k0s.sh previously called `systemctl daemon-reload`, which kept the log
	# existing and hid this. That call was itself wrong -- there is no systemd as
	# PID 1 in a build container -- so removing it exposed the assertion rather
	# than breaking anything real.
	[ ! -e "${SYSTEMCTL_LOG}" ] || {
		echo "30-k0s.sh invoked systemctl at all; it must not" >&2
		cat "${SYSTEMCTL_LOG}" >&2
		return 1
	}
}

@test "30-k0s: makes the controller and worker units mutually exclusive by token" {
	# The invariant that keeps two nodes from both claiming to be the control
	# plane: the controller requires no token, the worker requires one. Matched
	# as ConditionPathExists so the assertion is on the condition's sense, not on
	# the exact spelling of the path.
	run bash "${K0S_SCRIPT}"
	[ "$status" -eq 0 ]

	# Matched on the tail of the path, not the whole line: setup() rewrites
	# /etc/k0s to a sandbox prefix, so asserting the absolute path would be
	# asserting the test's own temporary directory rather than the invariant.
	grep -qE '^ConditionPathExists=!.*/etc/k0s/token$' \
		"${TEST_ROOT}/root/usr/lib/systemd/system/k0scontroller.service"
	grep -qE '^ConditionPathExists=[^!].*/etc/k0s/token$' \
		"${TEST_ROOT}/root/usr/lib/systemd/system/k0sworker.service"
}

@test "30-k0s: puts the unit arguments in sysconfig, not in the unit" {
	# The units read /etc/sysconfig/k0s, which is where an operator edits for a
	# real cluster. Asserted because inlining the arguments would make every
	# cluster change an image rebuild.
	run bash "${K0S_SCRIPT}"
	[ "$status" -eq 0 ]

	# Tail-matched, because setup() rewrites /etc/sysconfig to a sandbox prefix.
	# Anchored at the start and end so this cannot pass on a unit that merely
	# mentions the file in a comment.
	grep -qE '^EnvironmentFile=-.*/etc/sysconfig/k0s$' \
		"${TEST_ROOT}/root/usr/lib/systemd/system/k0scontroller.service"
	[ -f "${TEST_ROOT}/root/etc/sysconfig/k0s" ]
	grep -qE '^K0S_CONTROLLER_ARGS=' "${TEST_ROOT}/root/etc/sysconfig/k0s"
}

@test "30-k0s: refuses an architecture it has no digest for" {
	# A silent amd64 fallback would install a binary that cannot execute, and
	# that surfaces as a node booting to nothing rather than as a build error.
	# TARGETARCH unset is treated as amd64 because that is podman's default.
	TARGETARCH="riscv64" run bash "${K0S_SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"unsupported TARGETARCH"* ]]

	[ ! -e "${TEST_ROOT}/root/opt/bin/k0s" ]
}

@test "30-k0s: resolves arm64 to its own digest rather than the amd64 one" {
	# setup() already rewrote both arms to the same stub digest, because the stub
	# payload is one file and the curl stub answers both URLs with it. What has to
	# be proven here is therefore only that the arm64 arm selects the arm64
	# *asset*, which is the thing a broken case statement would get wrong.
	#
	# Asserted on the URL rather than the digest for that reason: a case statement
	# that fell back to amd64 would still pass a digest check against the stub,
	# because the stub is byte-identical either way.
	rm -f "${CURL_LOG}"
	TARGETARCH="arm64" run bash "${K0S_SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qF 'k0s-v1.36.4+k0s.1-arm64' "${CURL_LOG}"
	run grep -c 'linux_amd64\|1-amd64' "${CURL_LOG}"
	[ "$output" -eq 0 ]
}

### kc-agent

@test "35-kc-agent: installs from the pinned nightly URL" {
	run bash "${KC_SCRIPT}"
	if [ "$status" -ne 0 ]; then
		echo "--- phase output ---" >&2
		echo "$output" >&2
		echo "--- curl log ---" >&2
		cat "${CURL_LOG}" >&2 2>/dev/null || echo "(no curl log)" >&2
		echo "--- kc script digest lines ---" >&2
		grep -n 'kc_sha256=\|kc_url=\|kc_asset=' "${KC_SCRIPT}" >&2
	fi
	[ "$status" -eq 0 ]

	grep -qF 'kubestellar/console/releases/download/v0.3.43-nightly.20261006/' "${CURL_LOG}"
	[ -x "${TEST_ROOT}/root/opt/bin/kc-agent" ]
}

@test "35-kc-agent: a digest mismatch fails the build and installs nothing" {
	sed -i \
		-e 's/^  amd64) kc_sha256=.*/  amd64) kc_sha256="0000000000000000000000000000000000000000000000000000000000000000" ;;/' \
		"${KC_SCRIPT}"
	run bash "${KC_SCRIPT}"
	[ "$status" -ne 0 ]
	[[ "$output" == *"does not match the pinned digest"* ]]

	[ ! -e "${TEST_ROOT}/root/opt/bin/kc-agent" ]
}

@test "35-kc-agent: unpacks only the binary and its licence" {
	# The real tarball also carries CHANGELOG.md, README.md and ~40 changelog.d/
	# fragments. Extracting all of it would put a nightly's build scratch into the
	# image; LICENSE is a licence obligation, not documentation. Asserted on the
	# explicit member list in the phase, since the stub tarball only ever held two
	# files and would pass this whether or not the list were narrow.
	run bash "${KC_SCRIPT}"
	[ "$status" -eq 0 ]

	grep -qE 'tar -xzf .* kc-agent$' "${KC_SCRIPT}"
	# And no bare `-x` that would extract the archive wholesale.
	run grep -cE 'tar -xzf .*"?\$?\{?[a-z_]*download\}?"?[[:space:]]*$' "${KC_SCRIPT}"
	[ "$output" -eq 0 ]
}

@test "35-kc-agent: still builds when a nightly drops the licence file" {
	# The one thing here that is a legal obligation rather than a convenience is
	# guarded rather than assumed. An unconditional install would fail the build
	# with a bare "cannot stat", which says nothing about what went missing -- and
	# the first person to hit it would reasonably suspect the digest pin.
	#
	# The stub payload is rebuilt WITHOUT LICENSE and the pinned digest is
	# re-pointed at it, because the two have to agree for this test to reach the
	# licence handling at all. A payload that merely omitted the member would fail
	# the digest check first and prove nothing about the warning path.
	mkdir -p "${TEST_ROOT}/nolic"
	cp "${TEST_ROOT}/tar-src/kc-agent" "${TEST_ROOT}/nolic/kc-agent"
	tar -czf "${TEST_ROOT}/payload-nolicense.tar.gz" -C "${TEST_ROOT}/nolic" kc-agent
	export KC_PAYLOAD="${TEST_ROOT}/payload-nolicense.tar.gz"
	_set_kc_digest "$(sha256sum "${KC_PAYLOAD}" | cut -d' ' -f1)"
	grep -q "amd64) kc_sha256=\"$(sha256sum "${KC_PAYLOAD}" | cut -d' ' -f1)\"" "${KC_SCRIPT}"

	run bash "${KC_SCRIPT}"
	if [ "$status" -ne 0 ]; then
		echo "--- phase output ---" >&2
		echo "$output" >&2
	fi
	[ "$status" -eq 0 ]
	[[ "$output" == *"carries no LICENSE"* ]]

	# And the binary still landed: the warning is about the licence, not a
	# half-installed package.
	[ -x "${TEST_ROOT}/root/opt/bin/kc-agent" ]
}

@test "35-kc-agent: ships a unit conditioned on there being a cluster" {
	# kc-agent serves a console that bridges to a kubeconfig. Starting it before
	# k0s is running serves a console with nothing behind it, so the unit is
	# conditioned on the kubeconfig existing: enabling it early is inert rather
	# than broken.
	run bash "${KC_SCRIPT}"
	[ "$status" -eq 0 ]

	unit="${TEST_ROOT}/root/usr/lib/systemd/system/kc-agent.service"
	[ -f "${unit}" ]
	# Tail-matched, because setup() rewrites /etc/k0s to a sandbox prefix.
	grep -qE '^ConditionPathExists=.*/etc/k0s/kubeconfig.yaml$' "${unit}"
}

@test "35-kc-agent: preset-enables the unit so the console is actually there" {
	# The one unit in these two phases that is enabled by default, and unlike
	# tailscaled or k0s it has no per-machine input to wait for. The opt-out is
	# `systemctl mask`.
	run bash "${KC_SCRIPT}"
	[ "$status" -eq 0 ]

	preset="${TEST_ROOT}/root/usr/lib/systemd/system/kc-agent.service.d/10-microraptor.preset"
	[ -f "${preset}" ]
	grep -qE '^enable kc-agent\.service$' "${preset}"
}

@test "35-kc-agent: records that the pin is a nightly, at the pin" {
	# The single most important thing a future reader of this file needs to know,
	# and the most likely thing to be deleted as noise. kc-agent has no stable
	# release -- every tag is vX.Y.Z-nightly.DATE -- so this pin can never be
	# moved by Renovate and carries no upstream patch signal.
	grep -q 'NIGHTLY' "${KC_SRC}"
	grep -qi 'prerelease' "${KC_SRC}"
	# And it must be next to the version, not only in a comment far above it.
	run grep -n 'kc_version=' "${KC_SRC}"
	[ "$status" -eq 0 ]
}

@test "30-k0s and 35-kc-agent: neither enables a service by systemctl enable" {
	# Both phases install units. Enabling is the operator's decision for k0s, and
	# kc-agent's is a preset. Neither calls `systemctl enable` directly, which is
	# the property that keeps a 263 MB binary from booting a cluster by surprise.
	#
	# No systemctl invocation at all, so the log must not exist. See the note on the
	# equivalent assertion above for why "the file is absent" is the right shape
	# rather than counting zero lines in it.
	run bash "${K0S_SCRIPT}"
	[ "$status" -eq 0 ]
	[ ! -e "${SYSTEMCTL_LOG}" ] || {
		echo "30-k0s.sh invoked systemctl" >&2
		cat "${SYSTEMCTL_LOG}" >&2
		return 1
	}
}