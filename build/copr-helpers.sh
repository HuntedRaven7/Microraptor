#!/usr/bin/bash
set -euo pipefail

###############################################################################
# COPR Helper Functions
###############################################################################
# These helper functions follow the @ublue-os/bluefin pattern for managing
# COPR repositories in a safe, isolated manner.
###############################################################################

# DNF5_RETRY_ATTEMPTS bounds how many times a transaction is retried when a
# mirror answers 404 for a package. See dnf5-retry.sh for why that happens, and
# why neither a warm metadata cache nor libdnf's own retry covers it.
DNF5_RETRY_ATTEMPTS="${DNF5_RETRY_ATTEMPTS:-8}"

# shellcheck source=/dev/null
source "$(dirname "${BASH_SOURCE[0]}")/dnf5-retry.sh"

copr_install_isolated() {
	local copr_name="$1"
	shift
	local packages=("$@")

	if [[ ${#packages[@]} -eq 0 ]]; then
		echo "ERROR: No packages specified for copr_install_isolated"
		return 1
	fi

	repo_id="copr:copr.fedorainfracloud.org:${copr_name//\//:}"

	echo "Installing ${packages[*]} from COPR $copr_name (isolated)"

	# `dnf5 copr enable` autodetects the chroot from the base's os-release.
	# On Hummingbird that yields hummingbird-20251124-x86_64, which no COPR
	# carries, and the enable fails without naming a chroot. Copr's own error
	# lists the valid ones; a base that autodetects correctly needs this unset.
	if [[ -n "${COPR_CHROOT:-}" ]]; then
		dnf5 -y copr enable "$copr_name" "$COPR_CHROOT"
	else
		dnf5 -y copr enable "$copr_name"
	fi
	dnf5 -y copr disable "$copr_name"

	# Explicit propagation rather than relying on the caller's `set -e`. A
	# function whose last-but-one command fails should not go on to announce
	# success, and a caller that runs this without errexit -- a test harness, or
	# `if copr_install_isolated ...` -- would otherwise get a success it did not
	# earn. The failure message still comes from dnf5_retry.
	dnf5_retry "${DNF5_RETRY_ATTEMPTS}" -y install --enablerepo="$repo_id" "${packages[@]}" ||
		return $?

	echo "Installed ${packages[*]} from $copr_name"
}
