#!/usr/bin/env bats
# Unit tests for build/dnf5-retry.sh.
#
# The wrapper exists because the mirrors 404 a fraction of package downloads
# for reasons unrelated to the build. These tests pin the behaviour that matters
# to the build: a transaction that eventually succeeds must not fail the build,
# and one that never succeeds must. They also pin the two mistakes that look
# like fixes and are not -- retrying only the metadata, and reaching for libdnf's
# own retry knob -- so a later edit cannot quietly reintroduce either.
#
# Run with: bats tests/template/dnf5-retry_test.bats

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
RETRY_SRC="${SCRIPT_DIR}/../../build/dnf5-retry.sh"

setup() {
	TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/dnf5-retry.${BATS_TEST_NUMBER:-0}.$$"
	STUB_BIN="${TEST_ROOT}/stub-bin"
	DNF5_LOG="${TEST_ROOT}/logs/dnf5.log"
	SLEEP_LOG="${TEST_ROOT}/logs/sleep.log"
	ATTEMPTS_LOG="${TEST_ROOT}/logs/attempts"

	mkdir -p "${STUB_BIN}" "${TEST_ROOT}/logs"

	export PATH="${STUB_BIN}:${PATH}"
	export DNF5_LOG SLEEP_LOG ATTEMPTS_LOG

	# dnf5 succeeds unless FAIL_UNTIL says otherwise, in which case it records
	# the attempt number and fails while that number is below the threshold. So
	# FAIL_UNTIL=3 fails attempts 1 and 2 and succeeds on the third.
	cat >"${STUB_BIN}/dnf5" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${DNF5_LOG}"
attempts=$(cat "${ATTEMPTS_LOG}" 2>/dev/null || echo 0)
attempts=$((attempts + 1))
printf '%s' "${attempts}" > "${ATTEMPTS_LOG}"
if [[ -n "${FAIL_UNTIL:-}" ]] && ((attempts < FAIL_UNTIL)); then
	echo "Librepo error: Cannot download: All mirrors were tried" >&2
	exit 1
fi
exit 0
EOF
	chmod +x "${STUB_BIN}/dnf5"

	cat >"${STUB_BIN}/sleep" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${SLEEP_LOG}"
exit 0
EOF
	chmod +x "${STUB_BIN}/sleep"

	unset FAIL_UNTIL
}

teardown() {
	rm -rf "${TEST_ROOT}"
}

# Source the helper and run it, so each test reads as one call.
run_retry() {
	# shellcheck source=/dev/null
	source "${RETRY_SRC}"
	"$@"
}

@test "dnf5-retry: passes the arguments through to dnf5 untouched" {
	run run_retry dnf5_retry 3 install -y hyprland quickshell
	[ "$status" -eq 0 ]
	[ "$(cat "${DNF5_LOG}")" = "install -y hyprland quickshell" ]
}

@test "dnf5-retry: does not retry a transaction that works first time" {
	run run_retry dnf5_retry 5 install -y ghostty
	[ "$status" -eq 0 ]
	# One dnf5 call, and no backoff at all.
	[ "$(wc -l <"${DNF5_LOG}")" -eq 1 ]
	[ ! -s "${SLEEP_LOG}" ]
}

@test "dnf5-retry: a transaction that eventually succeeds does not fail the build" {
	# The whole reason the wrapper exists. Three attempts, the third works.
	FAIL_UNTIL=3 run run_retry dnf5_retry 8 install -y sddm tailscale
	[ "$status" -eq 0 ]
	[ "$(cat "${ATTEMPTS_LOG}")" -eq 3 ]
}

@test "dnf5-retry: retries the whole transaction, not only the metadata" {
	# A warm cache does not help: it is the .rpm that 404s. Every attempt must
	# re-issue the full install.
	FAIL_UNTIL=3 run run_retry dnf5_retry 8 install -y ghostty
	[ "$status" -eq 0 ]
	# Three dnf5 calls, each the complete install -- not makecache, then install.
	[ "$(wc -l <"${DNF5_LOG}")" -eq 3 ]
	[ "$(grep -c '^install -y ghostty$' "${DNF5_LOG}")" -eq 3 ]
	run grep -q 'makecache' "${DNF5_LOG}"
	[ "$status" -ne 0 ]
}

@test "dnf5-retry: never reaches for libdnf's own retry knob" {
	# --setopt=retries=N retries one HTTP request against one mirror. A mirror
	# that answers 404 has nothing to retry, so passing it would look like
	# mitigation while changing nothing.
	run run_retry dnf5_retry 3 install -y ghostty
	[ "$status" -eq 0 ]
	run grep -qE 'setopt=?[a-z]*retr' "${DNF5_LOG}"
	[ "$status" -ne 0 ]
}

@test "dnf5-retry: a transaction that never succeeds fails the build" {
	# The property that keeps this from masking a real error. Without it, a
	# missing package or a dependency conflict would be retried into a timeout
	# instead of reported.
	FAIL_UNTIL=999 run run_retry dnf5_retry 4 install -y nonexistent-package
	[ "$status" -ne 0 ]
	[ "$(cat "${ATTEMPTS_LOG}")" -eq 4 ]
}

@test "dnf5-retry: reports which command exhausted its attempts" {
	# The error has to name the transaction, or a failure in a 400-package
	# desktop install is unactionable.
	FAIL_UNTIL=999 run run_retry dnf5_retry 2 install -y hyprland
	[ "$status" -ne 0 ]
	[[ "$output" == *"install -y hyprland"* ]]
	[[ "$output" == *"after 2 attempts"* ]]
}

@test "dnf5-retry: backs off further on each retry" {
	# A constant delay would retry inside the window in which the mirror is
	# still serving the stale view that caused the 404.
	FAIL_UNTIL=4 run run_retry dnf5_retry 8 install -y ghostty
	[ "$status" -eq 0 ]

	mapfile -t delays <"${SLEEP_LOG}"
	[ "${#delays[@]}" -eq 3 ]
	local i
	for i in 1 2 3; do
		[ "${delays[$((i - 1))]}" -gt "${delays[$((i - 2))]}" ] 2>/dev/null || true
	done
	[ "${delays[0]}" -lt "${delays[1]}" ]
	[ "${delays[1]}" -lt "${delays[2]}" ]
}

@test "dnf5-retry: sleeps between attempts but not after the last one" {
	# N attempts means N-1 sleeps. Sleeping after the final failure only delays
	# the error the build is about to report.
	FAIL_UNTIL=3 run run_retry dnf5_retry 3 install -y ghostty
	[ "$status" -eq 0 ]
	[ "$(wc -l <"${SLEEP_LOG}")" -eq 2 ]
}

@test "dnf5-retry: warns on each retry so the log explains the delay" {
	# A build that takes an extra minute with no explanation reads as a hang.
	FAIL_UNTIL=2 run run_retry dnf5_retry 3 install -y ghostty
	[ "$status" -eq 0 ]
	[[ "$output" == *"attempt 1/3"* ]]
	[[ "$output" == *"retrying"* ]]
}

@test "dnf5-retry: a single attempt behaves like a plain dnf5 call" {
	# The tests above set DNF5_RETRY_ATTEMPTS=1 for speed; this is the case
	# where a caller has opted out of retrying and the failure must surface
	# immediately.
	FAIL_UNTIL=999 run run_retry dnf5_retry 1 install -y ghostty
	[ "$status" -ne 0 ]
	[ "$(cat "${ATTEMPTS_LOG}")" -eq 1 ]
	[ ! -s "${SLEEP_LOG}" ]
}

@test "dnf5-retry: requires at least one attempt" {
	# Zero would make the loop body never run and the function return success
	# without installing anything -- the silent-no-op failure mode.
	FAIL_UNTIL=999 run run_retry dnf5_retry 0 install -y ghostty
	[ "$status" -ne 0 ]
}

@test "dnf5-retry: is sourced by copr-helpers.sh, so COPR installs get it too" {
	# The two share the file so a repository one enables and the install that
	# follows get identical tolerance. Verified through copr-helpers.sh because
	# that is the path the package phase actually takes.
	run grep -qF 'dnf5-retry.sh' "${SCRIPT_DIR}/../../build/copr-helpers.sh"
	[ "$status" -eq 0 ]
	run grep -qF 'dnf5_retry "${DNF5_RETRY_ATTEMPTS}" -y install' \
		"${SCRIPT_DIR}/../../build/copr-helpers.sh"
	[ "$status" -eq 0 ]
}

@test "dnf5-retry: the attempt count is defaulted in the file that defines the function" {
	# It used to be defaulted in copr-helpers.sh instead, and this test asserted
	# that, which cemented the mistake instead of catching it.
	#
	# The variable is the only knob dnf5_retry has, and this file is the one that
	# defines dnf5_retry, so this is where a caller gets a value. A phase that
	# sources only dnf5-retry.sh -- because it needs no COPR -- got the function
	# and not the count, and died in the image with:
	#
	#   line 41: DNF5_RETRY_ATTEMPTS: unbound variable
	#
	# `set -u` was right about it. The unit suites could not see it either, because
	# they all export DNF5_RETRY_ATTEMPTS themselves to keep the retry loops fast.
	run grep -qE '^DNF5_RETRY_ATTEMPTS="\$\{DNF5_RETRY_ATTEMPTS:-[0-9]+\}"$' \
		"${SCRIPT_DIR}/../../build/dnf5-retry.sh"
	[ "$status" -eq 0 ]
}

@test "dnf5-retry: sourcing it alone yields a usable attempt count" {
	# Behavioural, to complement the grep above: that proves a default exists, this
	# proves a caller that sources only this file can actually use it. A grep cannot
	# tell a reachable default from one shadowed later in the file.
	#
	# The variable is unset in the environment first, so an inherited value from
	# the test runner cannot stand in for the default and make this pass vacuously.
	run env -u DNF5_RETRY_ATTEMPTS bash -c \
		'set -euo pipefail; source "$1"; printf "attempts=%s\n" "${DNF5_RETRY_ATTEMPTS}"' \
		_ "${SCRIPT_DIR}/../../build/dnf5-retry.sh"
	[ "$status" -eq 0 ]
	[[ "$output" == *"attempts="* ]]
	# Not empty: an empty expansion is the failure this guards, and `[ "$output" ==
	# *"attempts="* ]` alone would pass on it.
	[[ "$output" =~ attempts=([0-9]+) ]]
	[ "${BASH_REMATCH[1]}" -ge 1 ]
}

@test "dnf5-retry: every phase that calls dnf5_retry can reach an attempt count" {
	# The structural guard for the whole class of bug. A phase is fine if it
	# sources dnf5-retry.sh, or copr-helpers.sh (which sources it), or defaults
	# the variable itself -- which is what 30-kernel.sh and 40-nvidia.sh do.
	#
	# Discovered by scanning build/ rather than from a hand-kept list, so a phase
	# written today that forgets is caught today rather than at the next
	# `just build`, which is where this surfaced.
	local phase uses reachable
	while IFS= read -r phase; do
		[[ -n "${phase}" ]] || continue
		uses=$(grep -cE 'dnf5_retry "\$\{DNF5_RETRY_ATTEMPTS\}"' "${phase}" || true)
		[ "${uses}" -gt 0 ] || continue

		reachable=$(grep -cE 'source .*(dnf5-retry|copr-helpers)\.sh|^DNF5_RETRY_ATTEMPTS=' "${phase}" || true)
		if [ "${reachable}" -eq 0 ]; then
			echo "$(basename "${phase}") calls dnf5_retry but reaches no DNF5_RETRY_ATTEMPTS default" >&2
			return 1
		fi
	done < <(find "${SCRIPT_DIR}/../../build" -maxdepth 1 -type f -name '*.sh' | sort)
}

@test "dnf5-retry: rejects a non-numeric attempt count" {
	# `((attempts < 1))` on a non-numeric string evaluates as 0 in bash
	# arithmetic, so the numeric guard has to come first or "abc" would run the
	# loop 0 times and report success having installed nothing.
	run run_retry dnf5_retry abc install -y ghostty
	[ "$status" -ne 0 ]
	[ ! -s "${DNF5_LOG}" ]
}