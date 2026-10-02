#!/usr/bin/bash
set -euo pipefail

###############################################################################
# COPR Helper Functions
###############################################################################
# These helper functions follow the @ublue-os/bluefin pattern for managing
# COPR repositories in a safe, isolated manner.
###############################################################################

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
	dnf5 -y install --enablerepo="$repo_id" "${packages[@]}"

	echo "Installed ${packages[*]} from $copr_name"
}
