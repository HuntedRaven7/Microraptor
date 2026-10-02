#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Final cleanup
###############################################################################
# The last mutation before image metadata, init, and `bootc container lint`.
# It finalises package and Flatpak sources, then prunes build artifacts.
#
# CLEAN_ROOT is a test seam: it prefixes every filesystem path and defaults to
# "/" in the image build.
###############################################################################

CLEAN_ROOT="${CLEAN_ROOT:-/}"
REPOS_DIR="${CLEAN_ROOT}/etc/yum.repos.d"

echo "::group:: Finalise package repositories"

# Revert the build-time dnf settings the Containerfile installs.
dnf5 config-manager setopt keepcache=0
dnf5 versionlock clear

# Disable every third-party repository. copr_install_isolated already disables
# each COPR it uses; this is the backstop for anything else the build enabled.
disable_repo_file() {
	[[ -f "$1" ]] || return 0
	sed -i 's@enabled=1@enabled=0@g' "$1"
}

# One list, used both to close the repositories and to assert afterwards that
# none of them is still live. Keeping the two in step is the whole point: an
# entry added to the first loop and not the second is closed but unchecked, and
# one added only to the second is checked but never closed -- which is the worse
# of the two, because the build still succeeds and ships a live third-party
# source.
#
# Globs are collected unexpanded so a pattern matching nothing stays literal and
# is skipped by the `[[ -f ]]` test, rather than vanishing under nullglob and
# quietly narrowing the check.
third_party_repo_files=(
	"${REPOS_DIR}"/_copr:*.repo
	"${REPOS_DIR}"/_copr_*.repo
	"${REPOS_DIR}"/rpmfusion-*.repo
	"${REPOS_DIR}"/fedora-multimedia.repo
	"${REPOS_DIR}"/tailscale.repo
	"${REPOS_DIR}"/fedora-cisco-openh264.repo
	"${REPOS_DIR}"/fedora-coreos-pool.repo
	# Fedora is a build-time source only. A base with no repository of its own --
	# Hummingbird -- needs it to install anything at all, and 90-cleanup.sh is the
	# last phase that runs dnf5, so this is where it can be closed. Leaving it
	# live would let an installed system resolve a Fedora RPM that is not the
	# Hummingbird-rebuilt one, mixing two buildroots that were never tested
	# together. Its stanzas are named fedora-44 and fedora-44-updates inside
	# fedora.repo, so the file is matched by name rather than by stanza id.
	"${REPOS_DIR}"/fedora.repo
	# Terra: needed to resolve ghostty and mangowm during the build, closed here
	# so an installed system does not pull from a repository that carries no GPG
	# key. `gpgcheck=0` is why that matters more here than for the others --
	# there is no signature on a Terra package for the policy to check.
	"${REPOS_DIR}"/terra.repo
	# The NVIDIA repository, whose definition ships inside ublue-os-nvidia-addons.
	# 40-nvidia.sh enables it in-process, because nvidia-driver-selinux is
	# available only from there, but `config-manager setopt` does not rewrite the
	# file -- so it already reads enabled=0 here. Listed anyway, as the assertion
	# below is what would catch a future change that did write it.
	"${REPOS_DIR}"/negativo17-fedora-nvidia*.repo
	"${REPOS_DIR}"/nvidia-container-toolkit.repo
)

for repo_file in "${third_party_repo_files[@]}"; do
	disable_repo_file "${repo_file}"
done

# Fail loudly rather than shipping a third-party repository that is still live.
for repo_file in "${third_party_repo_files[@]}"; do
	[[ -f "${repo_file}" ]] || continue
	if grep -qE '^enabled=1' "${repo_file}"; then
		echo "::error::third-party repository still enabled: $(basename "${repo_file}")" >&2
		exit 1
	fi
done

echo "::endgroup::"

echo "::group:: Finalise Flatpak sources"

# The Fedora Flatpak remote must never be added on first boot. Guarded, because
# the unit is owned by whichever flatpak package the base ships: it is present
# on a Fedora desktop base, and a base that carries no flatpak at all has no
# unit to disable. `systemctl disable` on a missing unit exits non-zero, which
# would fail the build under `set -e`.
if systemctl list-unit-files flatpak-add-fedora-repos.service >/dev/null 2>&1; then
	systemctl disable flatpak-add-fedora-repos.service
	systemctl mask flatpak-add-fedora-repos.service
	rm -f "${CLEAN_ROOT}/usr/lib/systemd/system/flatpak-add-fedora-repos.service"
else
	echo "flatpak-add-fedora-repos.service not present on this base; nothing to disable"
fi

echo "::endgroup::"

echo "::group:: Finalise automatic updates"

# uupd owns the update policy; stop the desktop base's own updater racing it.
# Guarded so a base without the unit (for example a non-Silverblue base) still
# builds instead of failing on a missing unit.
systemctl disable rpm-ostreed-automatic.timer 2>/dev/null || true

echo "::endgroup::"

echo "::group:: Prune build artifacts"

rm -rf "${CLEAN_ROOT}/.gitkeep"
# Use -mindepth/-maxdepth instead of shell globs so these are no-ops when the
# directories are empty (e.g. /var/cache/{libdnf5,rpm-ostree} only exist as
# transient buildah cache mounts and are not present in this layer).
find "${CLEAN_ROOT}/var" -mindepth 1 -maxdepth 1 -type d \! -name cache -exec rm -fr {} \;
find "${CLEAN_ROOT}/var/cache" -mindepth 1 -maxdepth 1 -type d \! -name libdnf5 \! -name rpm-ostree -exec rm -fr {} \;

# Clear tmpfs-backed runtime directories without deleting the directories
# themselves. Buildah may have bind mounts in these paths during RUN, so
# replacing the mountpoint can fail with EBUSY.
for runtime_dir in tmp boot; do
	mkdir -p "${CLEAN_ROOT:?}/${runtime_dir}"
	find "${CLEAN_ROOT:?}/${runtime_dir}" -mindepth 1 -maxdepth 1 -print0 |
		while IFS= read -r -d '' entry; do
			if mountpoint -q "${entry}" 2>/dev/null; then
				continue
			fi
			rm -rf "${entry}"
		done
done

# /run can contain nested bind mounts created by the build container. Walk it
# depth-first so we can remove image-owned files like /run/dnf while leaving
# mounted files and any directories that still contain them alone.
mkdir -p "${CLEAN_ROOT:?}/run"
find "${CLEAN_ROOT:?}/run" -mindepth 1 -depth -print0 |
	while IFS= read -r -d '' entry; do
		if mountpoint -q "${entry}" 2>/dev/null; then
			continue
		fi
		if [[ -d "${entry}" ]]; then
			rmdir "${entry}" 2>/dev/null || true
			continue
		fi
		rm -f "${entry}"
	done

echo "::endgroup::"
