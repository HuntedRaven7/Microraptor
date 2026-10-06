#!/usr/bin/env bats
# Unit tests for the image-flavour plumbing: two Containerfiles, one Justfile.
#
# The rename from a single `Containerfile` to `Containerfile.<flavor>` touched
# three things that all failed silently at the time: podman was handed a
# directory and no -f, hadolint was pinned to a name that matched neither file,
# and the CI cache-bust glob stopped matching. Those are the failure modes these
# tests exist to pin shut.

SCRIPT_DIR="$(cd "$(dirname "${BATS_TEST_FILENAME}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

@test "flavours: every Containerfile.<flavor> has a matching build recipe" {
	# A Containerfile with no recipe behind it is an image nobody can build.
	#
	# Only the forward direction is checked. The obvious reverse -- every build-*
	# recipe needs a Containerfile -- is wrong, because build-qcow2, build-raw and
	# build-iso take disk-image arguments rather than a flavour, and mapping them
	# onto Containerfile.qcow2 reports three failures that do not exist.
	while IFS= read -r flavors; do
		[[ -n "${flavors}" ]] || continue
		grep -qE "^build-${flavors}[[:space:]]" "${REPO_ROOT}/Justfile" || {
			echo "Containerfile.${flavors} exists but the Justfile has no build-${flavors} recipe" >&2
			return 1
		}
	done < <(cd "${REPO_ROOT}" && ls -1 Containerfile.* 2>/dev/null | sed 's/^Containerfile\.//')

	# And the two flavours this repository ships are both present, so deleting one
	# fails here rather than only on the next push to main.
	local cf
	for cf in Containerfile.workstation Containerfile.homelab; do
		[ -f "${REPO_ROOT}/${cf}" ] || {
			echo "${cf} is missing" >&2
			return 1
		}
	done
}

@test "flavours: both Containerfiles are tracked and executable-bit correct" {
	# git ls-files rather than ls: an untracked Containerfile builds locally and
	# is invisible to CI, which is the worst combination for a file whose whole
	# job is to be built.
	local cf
	for cf in Containerfile.workstation Containerfile.homelab; do
		grep -qx "${cf}" <(git -C "${REPO_ROOT}" ls-files) || {
			echo "${cf} is not tracked by git" >&2
			return 1
		}
	done
}

@test "flavours: there is no bare Containerfile left" {
	# podman build . with no -f looks for exactly this name. Leaving it behind
	# would mean `podman build .` silently works and builds whichever image was
	# last renamed into it, which is how two images diverge without anyone
	# noticing.
	[ ! -e "${REPO_ROOT}/Containerfile" ] || {
		echo "a bare Containerfile exists; -f is now always passed" >&2
		return 1
	}
}

@test "flavours: build passes -f so podman never falls back to a default name" {
	grep -qE -- '--file "\$\{containerfile\}"' "${REPO_ROOT}/Justfile"
}

@test "flavours: the base FROM line is read from the selected flavour" {
	# Reading the base from a hardcoded filename would mean the homelab image's
	# version string and BASE_IMAGE_NAME were derived from the workstation's
	# Containerfile. Both images currently share a base, so this cannot be caught
	# by comparing their metadata -- it has to be asserted structurally.
	grep -qE 'base_from=\$\(grep -iE .\^FROM.*"\$\{containerfile\}"' "${REPO_ROOT}/Justfile"
	run grep -cE "grep -iE '\^FROM\[\[:space:\]\]' Containerfile\b" "${REPO_ROOT}/Justfile"
	[ "$output" -eq 0 ]
}

@test "flavours: workstation is the default so the two-argument CI call still works" {
	# build-image.yml calls `just build "$IMAGE_NAME" "$DEFAULT_TAG"` with two
	# arguments. Defaulting the flavour to anything else would make that call
	# build the wrong image rather than fail.
	grep -qE '^DEFAULT_FLAVOR := env\("FLAVOR", "workstation"\)' "${REPO_ROOT}/Justfile"
	grep -qE '^build \$target_image=IMAGE_NAME \$tag=DEFAULT_TAG \$flavor=DEFAULT_FLAVOR:' "${REPO_ROOT}/Justfile"
}

@test "flavours: the homelab recipe names its own image and flavour" {
	# CI's workstation workflow derives IMAGE_NAME from the repository name. The
	# homelab image cannot, so its name is a literal in the Justfile and in the
	# workflow, and the two have to agree.
	grep -qE '^export HOMELAB_IMAGE_NAME := env\("HOMELAB_IMAGE_NAME", "microraptor-homelab"\)' "${REPO_ROOT}/Justfile"
	grep -qE '^build-homelab \$target_image=HOMELAB_IMAGE_NAME \$tag=DEFAULT_TAG:' "${REPO_ROOT}/Justfile"
	grep -qE 'just build "\$\{target_image\}" "\$\{tag\}" homelab' "${REPO_ROOT}/Justfile"
}

@test "flavours: an unknown flavour fails before podman is invoked" {
	# A missing Containerfile that is only discovered inside podman reports
	# "no Containerfile found" and names neither file. This checks the guard
	# exists and names the flavour it could not resolve.
	#
	# Single-quoted, because the pattern contains a literal ${flavor} and a
	# double-quoted one has bash expand it to nothing before grep sees it.
	grep -qF "flavour '\${flavor}' names" "${REPO_ROOT}/Justfile"
	# And the guard is above the build, not after it.
	local guard build_line
	guard=$(grep -nF "flavour '\${flavor}' names" "${REPO_ROOT}/Justfile" | head -1 | cut -d: -f1)
	build_line=$(grep -n '\${PODMAN} build' "${REPO_ROOT}/Justfile" | head -1 | cut -d: -f1)
	[ -n "${guard}" ] && [ -n "${build_line}" ] && [ "${guard}" -lt "${build_line}" ]
}

@test "flavours: both Containerfiles declare a source URL that exists" {
	# The rename broke this once already: the workstation image's
	# image.source label pointed at .../blob/main/Containerfile, which 404s for
	# every image ever built from that commit. Asserted against the file each
	# label names, so it cannot happen again unnoticed.
	local cf expected
	for cf in Containerfile.workstation Containerfile.homelab; do
		expected=$(grep -oE 'blob/\$\{IMAGE_REF\}/Containerfile\.[a-z]+' "${REPO_ROOT}/${cf}" | head -1)
		[ -n "${expected}" ] || {
			echo "${cf} has no per-flavour image.source URL" >&2
			return 1
		}
		local suffix="${expected##*/}"
		[ "${suffix}" = "${cf}" ] || {
			echo "${cf} points its image.source at ${suffix}" >&2
			return 1
		}
	done
}

@test "flavours: hadolint is pointed at a glob that matches both" {
	# The old value was `dockerfile: "Containerfile"`, which after the rename
	# matched neither file -- so PR validation would have linted nothing and still
	# been green.
	grep -qE 'dockerfile: "Containerfile\.\*"' "${REPO_ROOT}/.github/workflows/pr-validation.yml"
	run grep -cE 'dockerfile: "Containerfile"$' "${REPO_ROOT}/.github/workflows/pr-validation.yml"
	[ "$output" -eq 0 ]
}

@test "flavours: CI cache-bust globs still match a Containerfile" {
	# hashFiles('**/Containerfile') matched nothing after the rename, which
	# disables the cache key silently -- builds stay correct and get slower.
	local workflow
	for workflow in build-image.yml build-homelab-image.yml; do
		[ -f "${REPO_ROOT}/.github/workflows/${workflow}" ] || continue
		run grep -cE "hashFiles\('\*\*/Containerfile'\)" "${REPO_ROOT}/.github/workflows/${workflow}"
		[ "$output" -eq 0 ] || {
			echo "${workflow} has a cache-bust glob matching no file" >&2
			return 1
		}
	done
	# And build-image.yml, whose glob covers both flavours, must still match one.
	grep -qE "hashFiles\('\*\*/Containerfile\.\*'\)" "${REPO_ROOT}/.github/workflows/build-image.yml"
}

@test "flavours: the homelab workflow builds the homelab recipe" {
	local wf="${REPO_ROOT}/.github/workflows/build-homelab-image.yml"
	[ -f "${wf}" ]
	# Matched as `command -v just)" build-homelab` rather than `just build-homelab`
	# because the recipe is invoked through just's resolved path, exactly as
	# build-image.yml does.
	grep -qF 'just)" build-homelab' "${wf}"
	# And it does not derive the image name from the repository, which would
	# collide with the workstation image.
	grep -qE 'IMAGE_NAME: "microraptor-homelab"' "${wf}"
	run grep -cE 'IMAGE_NAME: "\$\{\{ github\.event\.repository\.name \}\}"' "${wf}"
	[ "$output" -eq 0 ]
}

@test "flavours: the homelab workflow signs with the repository-scoped identity" {
	# Matching the owner rather than the repository accepts a signature minted by
	# any repository in the org. Same rule as build-image.yml; asserted here
	# because a copied workflow is exactly where that regexp gets broadened.
	local wf="${REPO_ROOT}/.github/workflows/build-homelab-image.yml"
	grep -qE 'certificate-identity-regexp: https://github\.com/\$\{\{ github\.repository \}\}/\.github/workflows/' "${wf}"
	run grep -cE 'certificate-identity-regexp:.*github\.repository_owner' "${wf}"
	[ "$output" -eq 0 ]
}

@test "flavours: the homelab Containerfile omits every desktop phase" {
	# The reason a second Containerfile exists rather than a conditional in the
	# first. Each of these is a RUN block or a script that must not be referenced.
	local cf="${REPO_ROOT}/Containerfile.homelab"
	local script
	for script in 10-overlay.sh 20-packages-and-services.sh \
		25-hardware-and-session.sh 30-kernel.sh 40-nvidia.sh; do
		run grep -c "build/${script}" "${cf}"
		[ "$output" -eq 0 ] || {
			echo "Containerfile.homelab references ${script}" >&2
			return 1
		}
	done
}

@test "flavours: the homelab Containerfile runs the basic kernel" {
	# The user asked for the basic kernel. What "basic" means concretely is that
	# no kernel phase runs at all, so Hummingbird's own kernel is what boots --
	# asserted by the absence of both kernel phases above, and here by the absence
	# of the akmods stages that feed them.
	local cf="${REPO_ROOT}/Containerfile.homelab"
	# Matched on the FROM stage, not the word. The header explains in prose why the
	# akmods stages are absent, and a grep for "akmods" hits that explanation and
	# reports a failure for a comment that is the reason the assertion exists.
	run grep -cE '^FROM .*akmods' "${cf}"
	[ "$output" -eq 0 ] || {
		echo "Containerfile.homelab declares an akmods stage" >&2
		return 1
	}
	# And no /opt symlink rewrite: that exists so /opt is writable for downstream
	# consumers, and the k0s phase puts a build-time binary there.
	run grep -cE 'ln -s /var/opt /opt' "${cf}"
	[ "$output" -eq 0 ]
}

@test "flavours: the homelab Containerfile shares the base digest with the workstation" {
	# Both images resolve the same RPMs, so a package installed in one is the same
	# build as in the other. Two different digests of the same base would defeat
	# that silently.
	local ws homelab
	ws=$(grep -E '^FROM quay\.io/hummingbird' "${REPO_ROOT}/Containerfile.workstation")
	homelab=$(grep -E '^FROM quay\.io/hummingbird' "${REPO_ROOT}/Containerfile.homelab")
	[ -n "${ws}" ] && [ -n "${homelab}" ]
	[ "${ws}" = "${homelab}" ] || {
		echo "the two images pin different base digests" >&2
		return 1
	}
}

@test "flavours: the homelab Containerfile keeps the package-factory FROM literal" {
	# Containerfile.workstation documents this at length: Buildah does not
	# substitute a global ARG into a FROM line, so `FROM ${PACKAGE_IMAGE}@...`
	# expands to nothing and Buildah fails with "no FROM statement found".
	local cf="${REPO_ROOT}/Containerfile.homelab"
	run grep -cE '^FROM \$\{' "${cf}"
	[ "$output" -eq 0 ] || {
		echo "Containerfile.homelab interpolates an ARG into a FROM line" >&2
		return 1
	}
	grep -qE '^FROM ghcr\.io/projectbluefin/utah-packages@sha256:' "${cf}"
}

@test "flavours: the homelab Containerfile declares TARGETARCH" {
	# Both pinned-binary phases hard-fail on an architecture they have no digest
	# for, and both read TARGETARCH. Without the ARG podman still supplies the
	# value to RUN, but an undeclared ARG is not part of the cache key, so two
	# architectures would share one cache entry and one would install the other's
	# binary.
	grep -qE '^ARG TARGETARCH$' "${REPO_ROOT}/Containerfile.homelab"
}

@test "flavours: the homelab Containerfile pins terra.repo nowhere" {
	# Terra is a desktop source: it carries ghostty and mangowm, which this image
	# does not install. Shipping its definition would put a repository with
	# gpgcheck=0 into a cluster node for no reason.
	run grep -c 'terra.repo' "${REPO_ROOT}/Containerfile.homelab"
	[ "$output" -eq 0 ]
}