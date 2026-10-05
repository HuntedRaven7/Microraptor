#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# dnf5 with mirror-flake tolerance
#
# Usage:  dnf5_retry <attempts> <dnf5 args...>
#
# The Fedora and Hummingbird mirrors return 404 for a fraction of .rpm requests
# through no fault of the configuration on either side. Measured here at roughly
# one request in three, and it moves: the same package succeeds on a later
# attempt, and a different package is the one that fails next time. A build that
# runs once therefore fails intermittently for reasons that have nothing to do
# with what it is building.
#
# Two things do not fix it, both of which look like they should:
#
#   - `dnf5 makecache` first. It warms metadata, not packages. The failure is
#     the .rpm download itself, so a warm cache changes nothing.
#   - `--setopt=retries=N`. That is libdnf's retry of an individual HTTP
#     request against one mirror. A mirror that answers 404 has nothing to
#     retry, and dnf5 does not fail over to a different mirror for it.
#
# So the whole transaction is retried, with a backoff long enough for the
# mirror's view of the repository to catch up. Every attempt re-runs dnf5
# against the current metadata, and packages already downloaded are cached, so
# a retry costs only the packages still missing.
#
# This is a wrapper rather than inline shell in the Containerfile so that every
# transaction in the build gets the same treatment. The package phase calls it
# through build/copr-helpers.sh, which is already sourced by every script that
# installs anything.
#
# Exits non-zero once the attempts are exhausted, so a genuine failure -- a
# missing package, a dependency conflict -- still fails the build rather than
# being retried into a timeout.
###############################################################################

dnf5_retry() {
	local attempts="$1"
	shift

	# Reject a zero or non-numeric count rather than running the loop zero times.
	# A loop that never executes falls through to `return 0`, which reports a
	# successful install having installed nothing -- the one failure mode this
	# function must not have, since its whole purpose is to distinguish "worked
	# on retry" from "did not work".
	if ! [[ "${attempts}" =~ ^[0-9]+$ ]] || ((attempts < 1)); then
		echo "::error::dnf5_retry: attempt count must be a positive integer, got '${attempts}'" >&2
		return 2
	fi

	local attempt delay
	for ((attempt = 1; attempt <= attempts; attempt++)); do
		if dnf5 "$@"; then
			return 0
		fi
		if ((attempt == attempts)); then
			echo "::error::dnf5 ${*} failed after ${attempts} attempts" >&2
			return 1
		fi
		# Linear backoff: 5s, 10s, 15s... The flake is a mirror briefly serving a
		# stale view of the repository, so waiting longer than the usual constant
		# is the whole point.
		delay=$((attempt * 5))
		echo "::warning::dnf5 ${*} failed (attempt ${attempt}/${attempts}); retrying in ${delay}s" >&2
		sleep "${delay}"
	done
}