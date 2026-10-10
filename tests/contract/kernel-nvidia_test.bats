#!/usr/bin/env bats
# Contract: the kernel and NVIDIA phases are wired into the Containerfile, and
# the two akmods bundles are pinned together.
#
# The pairing is the thing worth guarding. A kmod is compiled against one exact
# kernel-version-release, so a kernel that moves without its kmod produces an
# image whose GPU driver cannot load -- and that is invisible until a boot, on
# hardware the build never touches. The check here is that the digests are both
# pinned and that both phases exist in the order the Containerfile runs them.
#
# Run with: bats tests/contract/kernel-nvidia_test.bats

REPO_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd)"
CONTAINERFILE="${REPO_ROOT}/Containerfile.workstation"

# Line number of the first match for a pattern, or empty.
line_of() {
	grep -n "$1" "${CONTAINERFILE}" | head -n1 | cut -d: -f1
}

@test "kernel-nvidia: the OGC kernel phase runs before the NVIDIA phase" {
	local kernel_line nvidia_line
	kernel_line="$(line_of '/ctx/build/30-kernel.sh')"
	nvidia_line="$(line_of '/ctx/build/40-nvidia.sh')"
	[ -n "${kernel_line}" ]
	[ -n "${nvidia_line}" ]
	[ "${kernel_line}" -lt "${nvidia_line}" ]
}

@test "kernel-nvidia: both phases run before the cleanup phase" {
	# 90-cleanup.sh prunes /var and /run and reverts dnf settings. A kernel or
	# driver package installed after it would leave residue that bootc lint
	# rejects, and would bypass the keepcache reset.
	local nvidia_line cleanup_line
	nvidia_line="$(line_of '/ctx/build/40-nvidia.sh')"
	cleanup_line="$(line_of '/ctx/build/90-cleanup.sh')"
	[ -n "${nvidia_line}" ]
	[ -n "${cleanup_line}" ]
	[ "${nvidia_line}" -lt "${cleanup_line}" ]
}

@test "kernel-nvidia: both akmods bundles are pinned to a digest" {
	# Tags move under the build. Each bundle ships its own copy of the kernel
	# RPMs, so a tag bump can pair a kernel with modules built for a different
	# one -- and the failure only appears at boot.
	run grep -qE '^FROM ghcr\.io/ublue-os/akmods:[^@]+@sha256:[a-f0-9]{64} AS akmods-common$' "${CONTAINERFILE}"
	[ "$status" -eq 0 ]
	run grep -qE '^FROM ghcr\.io/ublue-os/akmods-nvidia-open:[^@]+@sha256:[a-f0-9]{64} AS akmods-nvidia$' "${CONTAINERFILE}"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the open module is the one used" {
	# RTX 30-series, including the 3060 Ti, is covered by the open driver, which
	# is also the only one that supports RTX 50-series. The closed module is for
	# older hardware. If this ever points at akmods-nvidia, the image stops
	# supporting the newest cards without anything failing at build time.
	run grep -qE '^FROM ghcr\.io/ublue-os/akmods-nvidia-open:' "${CONTAINERFILE}"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: both phase steps mount the build context" {
	# Every phase script is invoked as /ctx/build/NN-name.sh, which only exists
	# if the ctx stage is bind mounted into that step. Omitting the mount fails
	# with "/bin/sh: line 1: /ctx/build/30-kernel.sh: No such file or directory"
	# and exit 127 -- which reads like a missing script rather than a missing
	# mount, and cost two build cycles to diagnose.
	local script
	for script in 30-kernel.sh 40-nvidia.sh; do
		# The mount and the invocation have to be in the same RUN block, so find
		# the line each script is invoked on and check the block above it.
		local run_line
		run_line="$(line_of "/ctx/build/${script}")"
		[ -n "${run_line}" ]
		# Walk back to the RUN that owns this invocation.
		local block
		block="$(sed -n "1,${run_line}p" "${CONTAINERFILE}" |
			tac | sed -n '/^RUN /,$p' | tac)"
		[[ "${block}" == *"--mount=type=bind,from=ctx,source=/,target=/ctx"* ]] || {
			printf 'FAIL: the RUN that calls %s does not mount /ctx\n' "${script}" >&2
			return 1
		}
	done
}

@test "kernel-nvidia: both phase scripts are executable" {
	# The Containerfile invokes them directly rather than through `bash <path>`,
	# so a non-executable script fails the build with exit 127 and
	# "No such file or directory" -- which reads like a missing mount rather than
	# a missing execute bit, and costs a build cycle to diagnose.
	local script
	for script in build/30-kernel.sh build/40-nvidia.sh; do
		[ -x "${REPO_ROOT}/${script}" ] || {
			printf 'FAIL: %s is not executable; the Containerfile runs it directly\n' "${script}" >&2
			return 1
		}
	done
}

@test "kernel-nvidia: both bundles are bind mounted, never copied" {
	# The common bundle is ~150 MB of RPMs that must not ship. A COPY would put
	# them in a layer, and nothing after it would remove them.
	local line
	for line in 'from=akmods-common' 'from=akmods-nvidia'; do
		run grep -qE -- "--mount=type=bind,${line},.*ro" "${CONTAINERFILE}"
		[ "$status" -eq 0 ]
	done
}

@test "kernel-nvidia: the kernel phase refuses to install kernel-devel" {
	# kernel-devel pulls gcc, binutils and a C++ toolchain -- 121 packages and
	# roughly 500 MB of build tooling in an image that ships no compiler. The
	# install must name exactly three RPMs by path.
	# Matched on the install lines only. The words appear in the comment that
	# explains why kernel-devel is excluded, and grepping the whole file would
	# match that explanation and fail the test for the wrong reason.
	run grep -E 'kernel-\[0-9\]\*\.rpm' "${REPO_ROOT}/build/30-kernel.sh"
	[ "$status" -eq 0 ]
	run grep -E '^[^#]*kernel-devel' "${REPO_ROOT}/build/30-kernel.sh"
	[ "$status" -ne 0 ]
}

@test "kernel-nvidia: the kernel phase removes kernel-modules-core" {
	# The base's kernel-modules-core holds modules for the kernel being replaced.
	# Left in place, dnf5 satisfies it from Fedora and downgrades it to 6.19 --
	# a 7.2.8 core with 6.19 modules, which does not boot. Nothing requires it, so
	# removing it is correct rather than a workaround.
	run grep -q 'kernel-modules-core' "${REPO_ROOT}/build/30-kernel.sh"
	[ "$status" -eq 0 ]
	# And it must be removed, not upgraded.
	run grep -qE 'remove -y .*kernel-modules-core' "${REPO_ROOT}/build/30-kernel.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the NVIDIA phase supplies the synthetic kernel-uname-r" {
	# Fedora's kernel-core generates kernel-uname-r in a scriptlet. The OGC
	# kernel-core has no such scriptlet and nothing in the bundle provides it, so
	# without this the kmod cannot resolve and the build fails at the install.
	run grep -q 'kernel-uname-r' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the NVIDIA phase checks the kmod against the kernel" {
	# The check is the point of the split. Both scripts record and compare the
	# kernel-version-release, so a bundle bump that moves one and not the other
	# fails the build instead of producing an unbootable image.
	run grep -q 'ogc-kernel-version' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
	run grep -qE 'bundle_kver.*!=.*installed_kver|nothing provides|::error::kmod-nvidia targets' \
		"${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the kmod chain names no 32-bit package" {
	# The 32-bit packages require Fedora's i686 stack, which conflicts with this
	# base's openssl-libs. That conflict is the reason Steam is absent, and
	# pulling i686 in the kmod chain would reintroduce it in a place where the
	# failure is much harder to read.
	#
	# Scoped to the kmod install itself. The userspace install does mention i686,
	# because it filters on it -- that is covered separately, and the two must not
	# be conflated into one grep.
	run grep -E 'kmod-nvidia-\*\.rpm' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
	# Comments excluded: the group explains at length why the 32-bit packages are
	# left out, and a whole-block grep matches that explanation.
	local kmod_group
	kmod_group="$(sed -n '/^echo "::group:: Install the NVIDIA open kernel module"/,/^echo "::endgroup::"/p' \
		"${REPO_ROOT}/build/40-nvidia.sh")"
	[ -n "${kmod_group}" ]
	run grep -E '^[^#]*i686' <<<"${kmod_group}"
	[ "$status" -ne 0 ]
}

@test "kernel-nvidia: the shim is built in a throwaway stage, not in the image" {
	# rpm-build is a 54-package toolchain. Installing it in 40-nvidia.sh and
	# removing it afterwards still puts gcc and binutils through a layer of a
	# runtime image, which is the opposite of what this base is. The stronger
	# property is that the toolchain never appears in the image at all, so that
	# is what this asserts: no stage that the final image descends from installs
	# rpm-build.
	#
	# Read as: the shim stage does install rpm-build, but nothing the final image
	# is built from does.
	# Comments excluded: 40-nvidia.sh names rpm-build while explaining why it is
	# not installed there, and a whole-file grep would match that explanation.
	run grep -E '^[^#]*rpm-build' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -ne 0 ]
	run grep -q 'dnf5 install -y rpm-build' "${REPO_ROOT}/build/35-kernel-uname-r-shim.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the shim stage does not depend on the context stage" {
	# ctx copies the shim's output, so the shim stage mounting ctx would be a
	# dependency cycle -- which Buildah reports as an opaque stage-resolution
	# failure rather than as a cycle.
	# Scoped to the shim stage's own RUN block. The runtime phases mount ctx
	# legitimately -- ctx copies the shim's output, not the other way round -- so
	# a whole-file grep would fail on all seven of them.
	# From the shim-build FROM line up to the next FROM line. Every instruction
	# in the file is part of some stage, so "up to the next FROM" is the stage.
	local shim_block
	shim_block="$(awk '/^FROM .* AS shim-build$/{found=1} found{print} found&&/^FROM /&&!/AS shim-build$/{exit}' \
		"${CONTAINERFILE}")"
	[ -n "${shim_block}" ]
	run grep -q 'from=ctx' <<<"${shim_block}"
	[ "$status" -ne 0 ]
	# And it does depend on the akmods bundle, which is what makes the shim's
	# version agree with the kernel the runtime phases install.
	run grep -q 'from=akmods-common' <<<"${shim_block}"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the shim script is executable and invoked directly" {
	[ -x "${REPO_ROOT}/build/35-kernel-uname-r-shim.sh" ] || {
		printf 'FAIL: 35-kernel-uname-r-shim.sh is not executable\n' >&2
		return 1
	}
	# The Containerfile must set the bit too: git preserves it, but a COPY from a
	# context that lost it fails at exec with exit 127.
	run grep -qE '^COPY --chmod=755 build/35-kernel-uname-r-shim\.sh' "${CONTAINERFILE}"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the NVIDIA phase installs the shim rather than rebuilding it" {
	run grep -qF 'SHIM_RPM_DIR' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
	# The path has to be the context's, not the root's. The shim is copied into the
	# ctx stage and this phase mounts that stage at /ctx, so /out does not exist
	# here -- and `find` blames the missing directory rather than the mount.
	run grep -qF 'SHIM_RPM_DIR:-/ctx/out' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
	# And it fails loudly if the shim is absent, rather than letting dnf5 report
	# an unsatisfiable dependency that points nowhere near the real cause.
	run grep -q 'shim-build stage did not produce one' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the shim build verifies the provide it claims to add" {
	# A shim that builds but does not carry the capability would fail much later,
	# inside the runtime phase, as a dependency error pointing nowhere near the
	# stage that caused it.
	run grep -q 'Verified: provides kernel-uname-r' "${REPO_ROOT}/build/35-kernel-uname-r-shim.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the addons package is installed unconditionally, not gated on Secure Boot" {
	# nvidia-driver-selinux comes only from NEGATIVO17, and the addons package is
	# what carries that repository definition. Gating the install on Secure Boot --
	# which is how this was first written, on the assumption that the package was
	# about module signing -- makes the kmod chain fail on every non-Secure-Boot
	# build with a dependency that names a package nothing in the image provides.
	run grep -E '^[^#]*ublue-os-nvidia-addons' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
	# The Secure Boot probe must not be what guards it.
	run grep -q 'efivars' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -ne 0 ]
}

@test "kernel-nvidia: the NEGATIVO17 repository is corrected before use" {
	# The shipped repo files interpolate $releasever, which on this base expands to
	# 20251124-1.16.hum1 rather than a Fedora version. Every baseurl 404s, and
	# because the files carry skip_if_unavailable=1 dnf5 reports the repository as
	# enabled and empty, with no error at all.
	run grep -q 'releasever' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
	# The version is derived from the kernel the driver must match, or taken from
	# the Containerfile's FEDORA_MAJOR_VERSION.
	run grep -q 'FEDORA_MAJOR_VERSION' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the NEGATIVO17 extraction tolerates the architecture suffix" {
	# installed_kver is a full uname -r string: 7.2.8-ogc1.1.fc44.x86_64. A pattern
	# anchored to the end of the string finds nothing, and the fallback then yields
	# an empty version and fails -- which is what the first version of this did.
	# The pattern is: .fc followed by digits, then either a dot or end of string.
	run grep -qF 'fc\([0-9]\+\)\(\.\|$\)' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the NEGATIVO17 repository is asserted to be non-empty" {
	# A silently empty repository is the failure above, and the symptom downstream
	# is a missing nvidia-driver-selinux that points nowhere near the real cause.
	run grep -q 'nvidia-driver-selinux is unavailable' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the 32-bit driver packages are filtered by architecture" {
	# The bundle's nvidia/ directory holds both architectures side by side, so a
	# glob over it picks up nvidia-driver-libs, -common and -cuda-libs in i686.
	# Those need Fedora's 32-bit stack against this base's openssl-libs -- the same
	# conflict that keeps Steam out -- and it would surface as a broken Steam
	# install rather than as anything to do with the GPU driver.
	#
	# The filter has to read each RPM's own %ARCH; matching .i686 in the filename
	# would tie it to the file naming rather than to the package.
	run grep -q "rpm -qp --qf '%{ARCH}'" "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
	run grep -q 'i686)' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the userspace driver is checked against the kernel module" {
	# NVIDIA refuses to load a module whose driver version differs from the
	# userspace libraries, and says "API mismatch" without hinting that the two
	# halves came from different bundles. A bare package name would resolve against
	# whatever NEGATIVO17 publishes today, so this is a live risk.
	run grep -q 'userspace driver .* matches the kernel module' "${REPO_ROOT}/build/40-nvidia.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: cleanup closes the NVIDIA repository" {
	run grep -q 'negativo17-fedora-nvidia' "${REPO_ROOT}/build/90-cleanup.sh"
	[ "$status" -eq 0 ]
	run grep -q 'nvidia-container-toolkit' "${REPO_ROOT}/build/90-cleanup.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: cleanup closes and asserts from one shared list" {
	# Two separate lists of repositories is how one ends up checked but never
	# closed: the build succeeds, the assertion misses it, and the image ships a
	# live third-party source.
	local cleanup
	cleanup="$(grep -c 'third_party_repo_files\[@\]' "${REPO_ROOT}/build/90-cleanup.sh")"
	[ "${cleanup}" -eq 2 ]
	# And nothing outside that array disables a repository.
	run grep -cE '^disable_repo_file "\$\{REPOS_DIR\}/' "${REPO_ROOT}/build/90-cleanup.sh"
	[ "$status" -ne 0 ]
}

@test "kernel-nvidia: every FROM reference carries a well-formed digest" {
	# Shape only, deliberately: whether a digest still resolves is a property of
	# the registry, not of this repository, and a test that needed the network
	# would be a test that fails for reasons unrelated to the change under review.
	#
	# Shape is still worth asserting, because a digest copied out of a manifest
	# list rather than resolved for the platform is the kind of mistake that looks
	# correct in review -- 64 hex characters, right image, and unpullable.
	run grep -cE '^FROM [^ ]+:[^@]+@sha256:[a-f0-9]{64}( AS [a-z-]+)?$' "${CONTAINERFILE}"
	[ "$status" -eq 0 ]
	# Every FROM line, so a new unpinned stage cannot be added behind the count.
	# `scratch` is excluded: it is the reserved empty base and has no digest to
	# pin, and FROM scratch AS ctx is the only legitimate unpinned reference here.
	local from_lines pinned
	from_lines="$(grep -E '^FROM ' "${CONTAINERFILE}" | grep -vcE '^FROM scratch( AS [a-z-]+)?$')"
	pinned="$(grep -cE '^FROM [^ ]+:[^@]+@sha256:[a-f0-9]{64}( AS [a-z-]+)?$' "${CONTAINERFILE}")"
	[ "${from_lines}" -eq "${pinned}" ]
	# And there is exactly one scratch stage, so the exclusion cannot grow.
	run grep -cE '^FROM scratch' "${CONTAINERFILE}"
	[ "$status" -eq 0 ]
	[ "$output" -eq 1 ]
}

@test "kernel-nvidia: the shim stage is based on a stock image, not the runtime base" {
	# The shim stage must not inherit the image's own base. It exists to run
	# rpmbuild, and pinning it to the same base it is producing a package for
	# means a packaging problem in that base breaks the shim too.
	run grep -qE '^FROM [^ ]*fedora[^ ]*@sha256:[a-f0-9]{64} AS shim-build$' "${CONTAINERFILE}"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the kernel phase prunes orphaned module trees" {
	# `dnf5 remove` of the base kernel does not clean up after itself. kernel-core's
	# posttrans runs kernel-install and depmod, which write modules.dep and friends
	# into the tree; those are generated rather than packaged, so rpm does not own
	# them and does not remove them. The result is a directory rpm -qf reports as
	# belonging to nothing, holding 45 MB of an uninstalled kernel -- and a module
	# tree for a kernel that is not there is what a later kmod install picks up.
	run grep -q 'orphaned module tree' "${REPO_ROOT}/build/30-kernel.sh"
	[ "$status" -eq 0 ]
	# Scoped to the installed kernel's name, so it cannot delete the tree that was
	# just installed.
	run grep -qF '"/usr/lib/modules/${OGC_KVER}" ]] && continue' "${REPO_ROOT}/build/30-kernel.sh"
	[ "$status" -eq 0 ]
	# And asserted afterwards, because a tree that survived the loop would be very
	# hard to attribute to this script later.
	run grep -q 'does not belong to the installed kernel' "${REPO_ROOT}/build/30-kernel.sh"
	[ "$status" -eq 0 ]
}

@test "kernel-nvidia: the image keeps exactly one module tree" {
	# The end-to-end version of the test above, and the one that would have caught
	# it: two trees in a committed image means one of them is dead weight from a
	# kernel that is not installed.
	#
	# Skipped when the image has not been built, since this reads the local store
	# rather than the repository.
	local image="localhost/microraptor:stable-testing"
	command -v podman >/dev/null || skip "podman is not installed"
	podman image exists "${image}" 2>/dev/null || skip "${image} has not been built"

	run podman run --rm --entrypoint /bin/bash "${image}" -c \
		'rpm -q kernel --qf "%{VERSION}-%{RELEASE}.%{ARCH}\n"; ls -1 /usr/lib/modules/'
	[ "$status" -eq 0 ]

	local kernel trees extra
	kernel="$(head -n1 <<<"${output}")"
	trees="$(tail -n +2 <<<"${output}" | grep -c .)"
	extra="$(tail -n +2 <<<"${output}" | grep -vxF "${kernel}" | grep -c . || true)"

	[ "${trees}" -eq 1 ]
	[ "${extra}" -eq 0 ]
}
