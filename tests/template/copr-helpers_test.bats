#!/usr/bin/env bats
# Unit tests for build/copr-helpers.sh (copr_install_isolated).
# Run with: bats tests/template/copr-helpers_test.bats

SCRIPT_DIR="$(cd "$(dirname "$BATS_TEST_FILENAME")" && pwd)"
COPR_HELPERS_LIB="${SCRIPT_DIR}/../../build/copr-helpers.sh"

setup() {
    TEST_ROOT="${BATS_TEST_TMPDIR:-${BATS_TMPDIR}}/copr-helpers.${BATS_TEST_NUMBER:-0}.$$"
    STUB_BIN="${TEST_ROOT}/bin"
    DNF5_LOG="${TEST_ROOT}/dnf5.log"

    mkdir -p "${STUB_BIN}"
    export PATH="${STUB_BIN}:${PATH}"
    export COPR_HELPERS_LIB
    export DNF5_LOG
    unset DNF5_FAIL_MATCH
    unset DNF5_FAIL_CODE
    unset DNF5_FAIL_TIMES
    # One attempt by default: a test that stubs a failure should see it at once
    # rather than sitting through dnf5_retry's backoff.
    export DNF5_RETRY_ATTEMPTS=1
    # Per-test counter for the failure stub. It must not be a shared /tmp path:
    # a counter left over from an earlier test would make this one fail fewer
    # times than it asked for, and the retry count assertion would drift.
    export DNF5_COUNTER="${TEST_ROOT}/dnf5-fail-counter"

    # DNF5_FAIL_TIMES bounds how many matching calls fail before the stub starts
    # succeeding, so a retry test can model a transient failure. The counter is
    # only removed once the bound is passed -- deleting it on every failure would
    # reset the count and make the stub fail forever, which looks exactly like a
    # helper that never retries.
    cat >"${STUB_BIN}/dnf5" <<'EOF'
#!/usr/bin/bash
printf '%s\n' "$*" >> "${DNF5_LOG}"
if [[ -n "${DNF5_FAIL_MATCH:-}" && "$*" == *"${DNF5_FAIL_MATCH}"* ]]; then
    counter="${DNF5_COUNTER:-${TMPDIR:-/tmp}/dnf5-fail-counter}"
    n=$(cat "$counter" 2>/dev/null || echo 0)
    n=$((n + 1))
    printf '%s' "$n" > "$counter"
    if ((n <= ${DNF5_FAIL_TIMES:-100000})); then
        exit "${DNF5_FAIL_CODE:-1}"
    fi
    rm -f "$counter"
fi
exit 0
EOF
    chmod +x "${STUB_BIN}/dnf5"

    cat >"${STUB_BIN}/sleep" <<'EOF'
#!/usr/bin/bash
exit 0
EOF
    chmod +x "${STUB_BIN}/sleep"

    # shellcheck source=../../build/copr-helpers.sh
    source "${COPR_HELPERS_LIB}"
}

teardown() {
    rm -rf "${TEST_ROOT}"
}

@test "copr_install_isolated: enables, disables, then installs from the repo id" {
    run copr_install_isolated atim/starship starship

    [ "$status" -eq 0 ]
    [[ "$output" == *"Installing starship from COPR atim/starship (isolated)"* ]]
    [[ "$output" == *"Installed starship from atim/starship"* ]]

    mapfile -t calls <"${DNF5_LOG}"
    [ "${#calls[@]}" -eq 3 ]
    [ "${calls[0]}" = "-y copr enable atim/starship" ]
    [ "${calls[1]}" = "-y copr disable atim/starship" ]
    [ "${calls[2]}" = "-y install --enablerepo=copr:copr.fedorainfracloud.org:atim:starship starship" ]
}

@test "copr_install_isolated: disable runs before install so the repo stays off by default" {
    run copr_install_isolated ublue-os/staging ublue-update

    [ "$status" -eq 0 ]

    mapfile -t calls <"${DNF5_LOG}"
    disable_index=-1
    install_index=-1
    for i in "${!calls[@]}"; do
        [[ "${calls[$i]}" == *"copr disable"* ]] && disable_index="$i"
        [[ "${calls[$i]}" == *" install "* ]] && install_index="$i"
    done
    [ "$disable_index" -ge 0 ]
    [ "$install_index" -ge 0 ]
    [ "$disable_index" -lt "$install_index" ]
}

@test "copr_install_isolated: installs multiple packages in a single dnf5 transaction" {
    run copr_install_isolated atim/starship starship zsh fish

    [ "$status" -eq 0 ]

    mapfile -t calls <"${DNF5_LOG}"
    [ "${#calls[@]}" -eq 3 ]
    [ "${calls[2]}" = "-y install --enablerepo=copr:copr.fedorainfracloud.org:atim:starship starship zsh fish" ]
}

@test "copr_install_isolated: translates every slash in the copr name into the repo id" {
    run copr_install_isolated "owner/project" pkg

    [ "$status" -eq 0 ]

    mapfile -t calls <"${DNF5_LOG}"
    [[ "${calls[2]}" == *"--enablerepo=copr:copr.fedorainfracloud.org:owner:project"* ]]
    [[ "${calls[2]}" != *"owner/project "* ]]
}

@test "copr_install_isolated: fails when no packages are supplied" {
    run copr_install_isolated atim/starship

    [ "$status" -eq 1 ]
    [[ "$output" == *"ERROR: No packages specified for copr_install_isolated"* ]]
    [ ! -s "${DNF5_LOG}" ] || [ ! -f "${DNF5_LOG}" ]
}

@test "copr_install_isolated: does not enable the repo when no packages are supplied" {
    run copr_install_isolated ublue-os/staging

    [ "$status" -eq 1 ]
    [ ! -f "${DNF5_LOG}" ]
}

@test "copr_install_isolated: propagates dnf5 install failure" {
    export DNF5_FAIL_MATCH=" install "
    export DNF5_FAIL_CODE=23

    # Called directly rather than through `bash -c`: a subshell would not carry
    # the stub PATH set up in setup(), so the real dnf5 would run instead and the
    # test would assert against whatever the host happens to have.
    run copr_install_isolated atim/starship starship

    # Non-zero rather than the stub's own 23: dnf5_retry is a wrapper, and a
    # wrapper that reports which of its own attempts exhausted is more useful
    # than one that forwards a libdnf exit code the caller cannot act on.
    [ "$status" -ne 0 ]
    [[ "$output" == *"Installing starship from COPR atim/starship (isolated)"* ]]
    # The load-bearing assertion: a failed install must not be announced as one.
    [[ "$output" != *"Installed starship from atim/starship"* ]]
}

@test "copr_install_isolated: retries the install when a mirror 404s" {
    # The install goes through dnf5_retry, so a transient download failure is
    # retried rather than failing the build -- and the repo is still disabled
    # either way, so a retry cannot leave a third-party repository enabled.
    export DNF5_FAIL_MATCH=" install "
    export DNF5_FAIL_CODE=23
    export DNF5_FAIL_TIMES=2
    export DNF5_RETRY_ATTEMPTS=5

    run copr_install_isolated atim/starship starship

    [ "$status" -eq 0 ]
    [[ "$output" == *"Installed starship from atim/starship"* ]]
    # Three attempts: two failed, then one that worked.
    [ "$(grep -c 'install' "${DNF5_LOG}")" -eq 3 ]
    # And the COPR was disabled once, not once per attempt.
    [ "$(grep -c 'copr disable' "${DNF5_LOG}")" -eq 1 ]
}

@test "copr_install_isolated: propagates dnf5 copr enable failure without installing" {
    export DNF5_FAIL_MATCH="copr enable"
    export DNF5_FAIL_CODE=7

    run bash -c 'set -euo pipefail; source "$COPR_HELPERS_LIB"; copr_install_isolated atim/starship starship'

    [ "$status" -eq 7 ]
    mapfile -t calls <"${DNF5_LOG}"
    [ "${#calls[@]}" -eq 1 ]
    [ "${calls[0]}" = "-y copr enable atim/starship" ]
}

@test "copr-helpers.sh: sourcing the library performs no dnf5 calls" {
    run bash -c 'source "$COPR_HELPERS_LIB"'

    [ "$status" -eq 0 ]
    [ ! -f "${DNF5_LOG}" ]
}
