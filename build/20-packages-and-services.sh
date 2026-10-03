#!/usr/bin/env bash

set -euo pipefail


echo "::group:: Install Ghostty from Terra"

# Terra was installed and enabled by the Containerfile's package sources phase,
# so it is live here without a per-step --enablerepo. 90-cleanup.sh closes it,
# along with fedora.repo, before the image is committed.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y ghostty 

echo "::endgroup::"

if [[ -f /etc/yum.repos.d/utah.repo ]]; then
	sed -i 's/^enabled=1$/enabled=0/' /etc/yum.repos.d/utah.repo
	echo "::group:: Finalise the Utah package factory"
	if grep -qE '^enabled=1' /etc/yum.repos.d/utah.repo; then
		echo "::error::utah-packages is still enabled in /etc/yum.repos.d/utah.repo" >&2
		exit 1
	fi
	echo "utah-packages: enabled=0 (the factory mount does not survive this phase)"
	echo "::endgroup::"
else
	echo "::error::/etc/yum.repos.d/utah.repo is missing; cannot close the package factory" >&2
	exit 1
fi

# Restore default glob behavior
shopt -u nullglob
