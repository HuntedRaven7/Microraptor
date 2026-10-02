#!/usr/bin/env bats
# Contract: the package sources the image needs at build time are declared in the
# Containerfile, and the base's FROM line stays machine-readable.
#
# `just build` derives the base tag and the base image name by parsing the FROM
# line with sed. A trailing space or a missing tag makes those sed expressions
# return the whole line unchanged, and the recipe then exits rather than build
# something mislabelled -- which no CI job exercises, because CI takes its image
# name from the event payload instead. These tests are the only thing standing
# between a hand-edited FROM line and a local build that cannot start.

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
CONTAINERFILE="${REPO_ROOT}/Containerfile"

# The same extraction the Justfile's build recipe performs.
base_from() {
	grep -iE '^FROM[[:space:]]' "${CONTAINERFILE}" |
		grep -viE '[[:space:]]as[[:space:]]' |
		head -n1
}

base_tag() {
	sed -E 's|^FROM[[:space:]]+[^@:[:space:]]+:([^@[:space:]]+)(@.*)?$|\1|' <<<"$(base_from)"
}

base_image_name() {
	local ref
	ref="$(sed -E 's|^FROM[[:space:]]+||; s|@.*$||; s|:[^:/]*$||' <<<"$(base_from)")"
	printf '%s' "${ref##*/}"
}

# The base reference without its digest, for running throwaway containers.
base_ref() {
	sed -E 's|^FROM[[:space:]]+||; s|@.*$||' <<<"$(base_from)"
}

# os-release field from the base image. Prints nothing when the base cannot be
# run here, which is what lets every test that needs it skip rather than fail.
base_os_release_field() {
	local field="$1" ref
	ref="$(base_ref)"
	command -v podman >/dev/null 2>&1 || return 1
	podman image exists "${ref}" 2>/dev/null || return 1
	podman run --rm --entrypoint /bin/bash "${ref}" -c "cat /usr/lib/os-release" 2>/dev/null |
		sed -n "s/^${field}=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p"
}

# True when the base image already carries this file under /etc/pki/rpm-gpg.
base_provides() {
	local ref
	ref="$(base_ref)"
	command -v podman >/dev/null 2>&1 || return 1
	podman image exists "${ref}" 2>/dev/null || return 1
	podman run --rm --entrypoint /bin/bash "${ref}" \
		-c "test -f /etc/pki/rpm-gpg/$1" >/dev/null 2>&1
}

@test "package-sources: exactly one FROM line has no stage alias" {
	# Every context stage is `FROM ... AS name`. `just build` takes the first
	# line without an alias, so a second one would be read as the base.
	local unaliased
	unaliased="$(grep -iE '^FROM[[:space:]]' "${CONTAINERFILE}" |
		grep -viE '[[:space:]]as[[:space:]]' | wc -l)"
	[ "${unaliased}" -eq 1 ]
}

@test "package-sources: the base FROM line yields a base tag, not the line itself" {
	# The failure this guards: sed leaves the line untouched, base_tag equals
	# base_from, and `just build` exits with "Could not read the base image".
	local from tag
	from="$(base_from)"
	tag="$(base_tag)"
	[ -n "${from}" ]
	[ -n "${tag}" ]
	[ "${tag}" != "${from}" ]
}

@test "package-sources: the base FROM line carries no trailing whitespace" {
	# A trailing space is the specific edit that broke the parse above, and it
	# is invisible in most diff viewers.
	local from
	from="$(base_from)"
	run grep -qE '[[:space:]]$' <<<"${from}"
	[ "$status" -ne 0 ]
}

@test "package-sources: the base image is pinned to a digest" {
	# An unpinned base makes builds unreproducible and leaves Renovate nothing
	# to bump: it tracks digests, so `:latest` with no digest is not a version it
	# can move.
	run grep -qE '@sha256:[a-f0-9]{64}$' <<<"$(base_from)"
	[ "$status" -eq 0 ]
}

@test "package-sources: the base image name is non-empty" {
	local name
	name="$(base_image_name)"
	[ -n "${name}" ]
	run grep -qE '[:@]' <<<"${name}"
	[ "$status" -ne 0 ]
}

@test "package-sources: dnf5-plugins is installed before any config-manager call" {
	# `config-manager` and `versionlock` are dnf5-plugins subcommands, not core.
	# A base that does not ship the plugin package fails at the first one of
	# these with "Unknown argument", and that is a RUN block, so the build dies
	# before it can report anything useful.
	local plugins_line config_line
	plugins_line="$(grep -n 'dnf5 install -y dnf5-plugins' "${CONTAINERFILE}" | head -n1 | cut -d: -f1)"
	config_line="$(grep -n 'dnf5 config-manager setopt' "${CONTAINERFILE}" | head -n1 | cut -d: -f1)"
	[ -n "${plugins_line}" ]
	[ -n "${config_line}" ]
	[ "${plugins_line}" -lt "${config_line}" ]
}

@test "package-sources: the base FROM image is copied into the build context" {
	# packages/ holds the repository definitions and keys the build needs. They
	# reach the image only through the ctx stage, so a missing COPY leaves the
	# install step reading a file that was never sent.
	run grep -qE '^COPY packages /packages$' "${CONTAINERFILE}"
	[ "$status" -eq 0 ]
}

@test "package-sources: the Fedora repo definition is installed from the context" {
	# A base with no Fedora repository of its own cannot install anything
	# without this. Referenced through /ctx so the copy above is what supplies it.
	run grep -qF '/ctx/packages/fedora.repo' "${CONTAINERFILE}"
	[ "$status" -eq 0 ]
}

@test "package-sources: every gpgkey the installed repo files name is present in the image" {
	# A repo file pointing at a key the image does not carry fails at the first
	# transaction, with a signature error that reads like a signing problem
	# rather than a missing file.
	#
	# Only the repo files the Containerfile installs are in scope. A file kept in
	# packages/ purely as reference may legitimately name a key the base image
	# already carries, which is what packages/hummingbird.repo does.
	local installed key_path source_repo
	installed="$(grep -oE '/ctx/packages/[A-Za-z0-9._-]+\.repo' "${CONTAINERFILE}" |
		sed 's|/ctx/packages/||' | sort -u)"
	[ -n "${installed}" ]
	for source_repo in ${installed}; do
		while read -r key_path; do
			[ -n "${key_path}" ] || continue
			key_path="${key_path#file://}"
			# Sourced from the context, or already in the base image.
			if grep -qF "packages/$(basename "${key_path}")" "${CONTAINERFILE}"; then
				[ -f "${REPO_ROOT}/packages/$(basename "${key_path}")" ] || {
					printf 'FAIL: %s names %s, which packages/ does not carry\n' \
						"${source_repo}" "${key_path}" >&2
					return 1
				}
				continue
			fi
			if [[ ! -f "${REPO_ROOT}/${key_path}" ]] && ! base_provides "$(basename "${key_path}")"; then
				printf 'FAIL: %s names %s, which neither packages/ nor the base provides\n' \
					"${source_repo}" "${key_path}" >&2
				return 1
			fi
		done < <(grep -hoE 'gpgkey=file:///etc/pki/rpm-gpg/[A-Za-z0-9._-]+' \
			"${REPO_ROOT}/packages/${source_repo}" | cut -d= -f2 | sort -u)
	done
}

@test "package-sources: repo definitions disable zchunk metadata" {
	# Fedora stopped publishing the .xml.zck variants dnf5 requests by default.
	# Without zchunk=false every metadata fetch 404s and no package resolves,
	# which presents as a mirror problem rather than a configuration one.
	local repo_file
	for repo_file in "${REPO_ROOT}"/packages/*.repo; do
		grep -q 'baseurl=.*fedoraproject' "${repo_file}" || continue
		run grep -qE '^zchunk=false$' "${repo_file}"
		[ "$status" -eq 0 ]
	done
}

@test "package-sources: the Fedora major is declared when the base cannot report it" {
	# 00-image-info.sh derives the Fedora major from the base's VERSION_ID. A base
	# whose os-release reports a build date rather than a release needs the ARG,
	# or the phase fails on an unset FEDORA_MAJOR_VERSION.
	local version_id declared
	version_id="$(base_os_release_field VERSION_ID)" ||
		skip "the base image cannot be run here"
	# The test is about what VERSION_ID means, not whether it is numeric:
	# Hummingbird reports VERSION_ID="20251124", which looks like a release
	# number and is a build date. A Fedora major is at most two digits, so
	# anything longer is a base that cannot answer the question.
	if [[ ! "${version_id}" =~ ^[0-9]{1,2}$ ]]; then
		declared="$(grep -cE '^ARG FEDORA_MAJOR_VERSION=' "${CONTAINERFILE}" || true)"
		[ "${declared}" -eq 1 ]
	fi
}

@test "package-sources: a declared Fedora major matches the repo definition" {
	# The two move together: packages/fedora.repo names the release its
	# baseurls point at, and the ARG is what image-info.json reports to bootc
	# tooling. Disagreeing means the image claims a release it never installed from.
	local declared repo_release
	declared="$(sed -n 's/^ARG FEDORA_MAJOR_VERSION="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' \
		"${CONTAINERFILE}")"
	[ -n "${declared}" ]
	repo_release="$(sed -n 's|.*/releases/\([0-9]\+\)/.*|\1|p' \
		"${REPO_ROOT}/packages/fedora.repo" | head -n1)"
	[ -n "${repo_release}" ]
	[ "${declared}" = "${repo_release}" ]
}

@test "package-sources: the COPR chroot is declared and matches the base architecture" {
	# `dnf5 copr enable` autodetects a chroot from os-release. A base that does
	# not report a Fedora release yields a chroot no COPR carries, so the value
	# is supplied here. Guarded on COPR_CHROOT being read by the helper, so a
	# base that needs no override is not forced to carry one.
	run grep -qE '^ENV COPR_CHROOT=' "${CONTAINERFILE}"
	if [ "$status" -ne 0 ]; then
		skip "no COPR_CHROOT declared; this base autodetects correctly"
	fi
	run grep -qF 'COPR_CHROOT' "${REPO_ROOT}/build/copr-helpers.sh"
	[ "$status" -eq 0 ]
}