#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# NVIDIA, open kernel module
#
# Installs the nvidia-open kmod from ublue-os/akmods-nvidia-open, built against
# the OGC kernel that 30-kernel.sh installed. The two are one unit: the kmod is
# compiled for one exact kernel-version-release, so the versions are checked
# against each other rather than assumed to match.
#
# RTX 30-series (including the 3060 Ti) is covered by the open driver. The open
# module is also the only one that supports RTX 50-series; the closed module is
# for older hardware and is not installed here.
#
# Upstream's own installer, nvidia-install.sh, is NOT run. It is written for a
# Fedora desktop and reaches for fedora-nvidia, negativo17, i686 multilib and a
# conditional on the image name. On this base the multilib step is exactly what
# makes Steam unresolvable -- it needs Fedora's i686 stack against Hummingbird's
# own openssl-libs. What it does to the repositories IS reproduced below, because
# one of them is a hard requirement rather than a convenience; see the NEGATIVO17
# group for why. The rest is installed directly, which is also what makes the
# revert obvious.
###############################################################################

# The bundle's layout is rpms/kmods, rpms/nvidia and rpms/ublue-os. Note this
# differs from what the upstream README implies -- it writes paths like
# ${AKMODNV_PATH}/kmods/nvidia-vars, which would be correct only if the mount
# were rooted at the bundle's rpms/ directory. The mount is rooted at the image
# root instead, so the rpms/ level has to be part of the path here.
AKMODNV_PATH="${AKMODNV_PATH:-/akmods-nvidia/rpms}"

echo "::group:: Check the NVIDIA bundle against the installed kernel"

if [[ ! -d "${AKMODNV_PATH}/kmods" ]]; then
	echo "::error::No kmods at ${AKMODNV_PATH}/kmods; the akmods stage did not land" >&2
	exit 1
fi
echo "akmods bundle: ${AKMODNV_PATH}"

# shellcheck source=/dev/null
source /ctx/build/dnf5-retry.sh
DNF5_RETRY_ATTEMPTS="${DNF5_RETRY_ATTEMPTS:-8}"

# The kernel this module must match. 30-kernel.sh wrote it; if it is missing the
# phases ran out of order, and installing a kmod for an unknown kernel is worse
# than not installing one.
if [[ ! -r /run/ogc-kernel-version ]]; then
	echo "::error::No kernel version recorded; 30-kernel.sh must run before this" >&2
	exit 1
fi
installed_kver="$(cat /run/ogc-kernel-version)"
echo "Kernel installed by 30-kernel.sh: ${installed_kver}"

# The bundle declares its own target. Checked rather than trusted: a tag bump can
# move the kmod without moving the kernel, and the failure that produces is a
# module that loads but claims the wrong kernel version.
bundle_kver="$(sed -n 's/^KERNEL_VERSION=//p' "${AKMODNV_PATH}/kmods/nvidia-vars")"
if [[ "${bundle_kver}" != "${installed_kver}" ]]; then
	echo "::error::kmod is built for kernel ${bundle_kver}, but ${installed_kver} is installed" >&2
	exit 1
fi

# kernel-uname-r is a synthetic provide. Fedora's kernel-core generates it in a
# scriptlet; the OGC kernel-core has no such scriptlet, so nothing in the image
# provides it and the kmod cannot resolve:
#
#   nothing provides kernel-uname-r = 7.2.8-ogc1.1.fc44.x86_64 needed by kmod-nvidia
#
# Nothing in the akmods bundle provides it either. The Containerfile's shim-build
# stage produces a small RPM carrying exactly that Provide, and copies it here.
# rpm-build is a 54-package toolchain, which is why it runs in a throwaway stage
# rather than in this one -- gcc and binutils must never pass through a layer of a
# runtime image.
#
# Guarded so a base that does provide it, or a future OGC kernel that starts
# generating it, does not end up with two providers for one capability.
# The shim lands in the build context's /out, and this phase mounts that context
# at /ctx -- so the path is /ctx/out. Reading /out here finds nothing, and
# `find` reports the missing directory rather than the mount that explains it.
SHIM_RPM_DIR="${SHIM_RPM_DIR:-/ctx/out}"
if rpm -q --whatprovides "kernel-uname-r = ${installed_kver}" >/dev/null 2>&1; then
	echo "kernel-uname-r already provided; skipping the shim"
else
	shim="$(find "${SHIM_RPM_DIR}" -name 'kernel-uname-r-*.rpm' -print -quit)"
	if [[ -z "${shim}" ]]; then
		echo "::error::no kernel-uname-r shim in ${SHIM_RPM_DIR}; the shim-build stage did not produce one" >&2
		exit 1
	fi
	echo "Installing the kernel-uname-r shim: ${shim}"
	dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y "${shim}"
fi

echo "::endgroup::"

echo "::group:: Add the NEGATIVO17 repository"

# nvidia-kmod-common carries a conditional requirement:
#
#   nvidia-driver-selinux if selinux-policy-targeted
#
# This base has selinux-policy-targeted, so the dependency is live -- and
# nvidia-driver-selinux is in neither the akmods bundle nor Fedora 44. It ships
# only in negativo17, whose repository definition is packaged inside
# ublue-os-nvidia-addons, which *is* in the bundle. So the addons package is a
# hard requirement of this phase, not the Secure Boot nicety its name suggests.
# Without it the kmod chain below fails on a dependency that looks unsatisfiable.
#
# Two corrections are needed before that repo is usable, both of which upstream's
# nvidia-install.sh also makes and neither of which is obvious from the failure:
#
#  1. $releasever. The shipped repo files interpolate it, and on this base it
#     expands to 20251124-1.16.hum1 rather than a Fedora version. Every baseurl
#     404s, and because the repo files carry skip_if_unavailable=1 dnf5 reports
#     the repository as enabled and holding zero packages, with no error. The
#     same trap is why packages/terra.repo spells its version out literally.
#     dnf5 offers no per-repository releasever override -- both
#     `--setopt=<repo>.releasever=` and `config-manager setopt` reject it -- so
#     the files are rewritten in place.
#
#  2. enabled=0. The shipped files are disabled by default and have to be turned
#     on before the metadata is fetched.
#
# Only fedora-nvidia is enabled, deliberately. The addons package also ships
# nvidia-container-toolkit.repo, which is for GPU access from containers and
# would add a repository that then has to be closed again for no benefit here;
# and fedora-nvidia-lts, which is the *closed* driver and would conflict with the
# open module installed below.
#
# That enable is process-local. `config-manager setopt` changes the in-memory
# configuration for this dnf5 process and does not rewrite the file, so the
# repository file still says enabled=0 in the committed image -- which is the
# outcome wanted, and the same one 90-cleanup.sh enforces for the others. Nothing
# here has to be undone afterwards, and there is no window in which an installed
# system could resolve from a repository the image did not mean to leave live.
#
# Driver updates do not come from here regardless. The kernel module is a pinned
# OCI bundle rather than a dnf package, so the driver moves when the akmods digest
# does. The only thing taken from this repository is nvidia-driver-selinux, a
# policy package that does not change between driver releases.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
	"${AKMODNV_PATH}"/ublue-os/ublue-os-nvidia-addons-*.rpm

# Which Fedora the negativo17 repository should point at. The Containerfile's
# FEDORA_MAJOR_VERSION is the declared value; when it is not in the environment
# the version is read out of the OGC kernel release instead, because that is the
# thing the driver has to match and the repository has to agree with it. A
# mismatch here would pair a driver with a repository for a different Fedora, and
# deriving both from the same string is what makes that impossible.
#
# The pattern matches .fcNN anywhere in the release rather than only at the end.
# installed_kver is a full uname -r string and carries the architecture --
# 7.2.8-ogc1.1.fc44.x86_64 -- so anchoring to the end finds nothing and the
# fallback fails open on an empty version instead of producing a wrong one.
# Requiring the digits to be followed by a dot or the end of the string keeps
# .fc44 from matching inside a longer run of digits.
if [[ -z "${FEDORA_MAJOR_VERSION:-}" ]]; then
	FEDORA_MAJOR_VERSION="$(sed -n 's/.*\.fc\([0-9]\+\)\(\.\|$\).*/\1/p' <<<"${installed_kver}")"
fi
if [[ -z "${FEDORA_MAJOR_VERSION}" ]]; then
	echo "::error::cannot determine the Fedora version for the negativo17 repository" >&2
	echo "::error::set FEDORA_MAJOR_VERSION, or use a kernel release ending in .fcNN" >&2
	exit 1
fi
echo "NEGATIVO17 repository will target Fedora ${FEDORA_MAJOR_VERSION}"

for repo_file in /etc/yum.repos.d/negativo17-fedora-nvidia*.repo; do
	if [[ ! -f "${repo_file}" ]]; then
		continue
	fi
	# $releasever only. $basearch is left alone: it resolves from the build
	# architecture and is correct as shipped.
	sed -i "s@\\\$releasever@${FEDORA_MAJOR_VERSION}@g" "${repo_file}"
done

dnf5 config-manager setopt 'fedora-nvidia.enabled=1' >/dev/null
for attempt in 1 2 3 4 5 6 7 8; do
	if dnf5 -q makecache --refresh; then
		break
	fi
	echo "::warning::makecache failed (attempt ${attempt}/8); retrying" >&2
	sleep $((attempt * 5))
done

# Assert the repository is actually usable. A silently empty repo is the failure
# mode described above, and the kmod install below would then report a missing
# nvidia-driver-selinux that points nowhere near the real cause.
if ! dnf5 -q list --available nvidia-driver-selinux 2>/dev/null | grep -q '^nvidia-driver-selinux'; then
	echo "::error::the fedora-nvidia repository resolved to no packages, so nvidia-driver-selinux is unavailable" >&2
	echo "::error::check the baseurl and that Fedora ${FEDORA_MAJOR_VERSION} is published there" >&2
	exit 1
fi
echo "nvidia-driver-selinux is available from fedora-nvidia"

echo "::endgroup::"

echo "::group:: Install the NVIDIA open kernel module"

# The dependency chain, in the order dnf5 needs:
#
#   kmod-nvidia        -> nvidia-kmod-common, kernel-uname-r
#   nvidia-kmod-common -> nvidia-kmod (the kmod itself), nvidia-modprobe,
#                         nvidia-driver-selinux
#   nvidia-modprobe    -> ships modprobe configs for the nvidia device nodes
#
# Passing the paths rather than names matters for the same reason as the kernel:
# a bare `nvidia-driver` would resolve against Fedora or negativo17 and pull a
# driver built for a different kernel.
#
# The i686 packages the upstream installer would add are deliberately omitted.
# They require Fedora's 32-bit stack, which conflicts with this base's
# openssl-libs -- the same conflict that keeps Steam out of the image.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
	"${AKMODNV_PATH}"/nvidia/nvidia-modprobe-*.rpm \
	"${AKMODNV_PATH}"/nvidia/nvidia-kmod-common-*.rpm \
	"${AKMODNV_PATH}"/kmods/kmod-nvidia-*.rpm

echo "::endgroup::"

echo "::group:: Install the NVIDIA userspace driver"

# The bundle's nvidia/ directory holds both architectures side by side, and a
# glob over it silently picks up the 32-bit half:
#
#   nvidia-driver-common-615.71.09-4.fc44.i686.rpm
#   nvidia-driver-cuda-libs-615.71.09-4.fc44.i686.rpm
#   nvidia-driver-libs-615.71.09-4.fc44.i686.rpm
#
# Those are the packages that require Fedora's i686 stack against this base's own
# openssl-libs -- the same conflict that keeps Steam out of the image. Installing
# them here would reintroduce that constraint from a direction nobody would
# expect, and the failure it causes surfaces much later as a broken Steam
# install rather than as anything to do with the GPU driver.
#
# So the list is built by asking each RPM for its architecture and skipping i686,
# rather than by globbing and hoping. Naming the arch in the filename would also
# work but ties the filter to the file naming rather than to the package.
#
# egl-wayland and libva-nvidia-driver come from Fedora, not the bundle: they carry
# no kernel code, so there is no reason to take them from a bundle pinned to one
# kernel. nvidia-container-toolkit is skipped -- it is for GPU access from
# containers, which this image does not set up, and its repository is not enabled.
driver_rpms=()
for rpm_file in "${AKMODNV_PATH}"/nvidia/*.rpm; do
	[[ -f "${rpm_file}" ]] || continue
	case "$(rpm -qp --qf '%{ARCH}' "${rpm_file}")" in
		i686)
			echo "Skipping 32-bit $(basename "${rpm_file}")"
			continue
			;;
	esac
	driver_rpms+=("${rpm_file}")
done

if [[ "${#driver_rpms[@]}" -eq 0 ]]; then
	echo "::error::no 64-bit NVIDIA userspace RPMs in ${AKMODNV_PATH}/nvidia" >&2
	exit 1
fi

dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
	"${driver_rpms[@]}" \
	egl-wayland \
	libva-nvidia-driver \
	mesa-vulkan-drivers

echo "::endgroup::"

echo "::group:: Enable NVIDIA services"

# ublue-os-nvidia-addons was installed unconditionally above, for the NEGATIVO17
# repository rather than for Secure Boot. It is the package that carries the
# Secure Boot signing key for the NVIDIA module, so on a Secure Boot machine that
# capability is now present too -- no separate step needed, and none that would
# have to be skipped when the addons are already installed.

# persistenced keeps the GPU initialised across suspend cycles, which is a real
# failure mode on a laptop that suspends mid-session.
systemctl enable nvidia-persistenced.service

# The module itself. load_modules is off across this base's preset policy, and
# an NVIDIA driver that is never loaded is an NVIDIA driver that does not work.
systemctl enable nvidia-hibernate.service 2>/dev/null || true

echo "::endgroup::"

echo "::group:: Verify the module matches the kernel"

# The one thing that can be checked without hardware: that the module that would
# be loaded was built for the kernel in the image. A mismatch is the failure the
# two-phase split exists to prevent, and it is invisible until a boot.
#
# The kernel to compare against comes from the bundle's own nvidia-vars, not from
# the installed package's version. kmod-nvidia's %{VERSION}-%{RELEASE} is the
# *driver* version (615.71.09-2.fc44), which has nothing to do with the kernel it
# was compiled against -- comparing it to the kernel version would never match,
# and comparing nothing at all would let a real mismatch through.
#
# nvidia-vars is checked above against the kernel 30-kernel.sh installed, so
# reaching here means the two bundles agree. What is asserted here is that the
# module's files actually landed and are for that kernel.
if ! rpm -q kmod-nvidia >/dev/null 2>&1; then
	echo "::error::kmod-nvidia is not installed" >&2
	exit 1
fi

# The kmod carries the kernel it targets in its own filename, which is the only
# place the pairing survives once installed.
kmod_file="$(rpm -ql kmod-nvidia 2>/dev/null | grep -m1 'nvidia\.ko' || true)"
if [[ -z "${kmod_file}" ]]; then
	echo "::error::kmod-nvidia is installed but ships no module file" >&2
	exit 1
fi
case "${kmod_file}" in
	*/"${installed_kver}"/*)
		echo "kmod-nvidia module path matches the installed kernel: ${kmod_file}"
		;;
	*)
		echo "::error::kmod-nvidia file is ${kmod_file}, kernel is ${installed_kver}" >&2
		exit 1
		;;
esac

# The userspace driver has to be the same driver release as the kernel module.
# NVIDIA enforces this: a mismatch does not degrade, it refuses to load, and the
# message ("API mismatch") gives no hint that the two halves came from different
# bundles. It is a live risk now that a third repository is enabled -- a bare
# name would have resolved against negativo17 and picked up whatever it publishes
# today rather than what this bundle pins.
#
# The kernel module's version is the driver version, which is exactly what is
# wanted here and is why it is not the string compared above.
module_drv="$(rpm -q kmod-nvidia --qf '%{VERSION}' 2>/dev/null || echo none)"
if ! rpm -q nvidia-driver >/dev/null 2>&1; then
	echo "::error::nvidia-driver is not installed; the userspace half of the driver is missing" >&2
	exit 1
fi
userspace_drv="$(rpm -q nvidia-driver --qf '%{VERSION}' 2>/dev/null || echo none)"
if [[ "${module_drv}" != "${userspace_drv}" ]]; then
	echo "::error::kernel module is driver ${module_drv} but userspace is ${userspace_drv}" >&2
	echo "::error::the NVIDIA module and library versions must be identical" >&2
	exit 1
fi
echo "userspace driver ${userspace_drv} matches the kernel module"

echo "::endgroup::"