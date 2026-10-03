#!/usr/bin/env bash

set -euo pipefail


echo "::group:: Install Ghostty from Terra"

dnf5 install -y ghostty steam

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
