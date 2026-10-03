#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# OGC kernel
#
# Replaces Hummingbird's kernel with the Open Gaming Collective build that
# ublue-os/akmods publishes, so the kmods in the NVIDIA phase match it. Without
# this the kmods cannot load: they are built against one exact
# kernel-version-release, and Hummingbird ships a different one.
#
# Two things about the base make this more than a package install, and both
# were established by reading the RPMs rather than assumed:
#
# 1. kernel-modules-core must be REMOVED, not upgraded.
#
#    The base carries kernel-modules-core 7.2.7, holding modules for the kernel
#    being replaced. Left in place, dnf5 tries to satisfy it from Fedora and
#    downgrades it to 6.19.10 -- pairing a 7.2.8 core with 6.19 modules, which
#    does not boot. Removing it is correct rather than a workaround:
#    `rpm -q --whatrequires kernel-modules-core` on the base returns nothing, and
#    the OGC kernel-core does not require it either. It only ever held modules
#    for the kernel being removed.
#
# 2. The RPMs must be named by path, never by bare package name.
#
#    `dnf5 install kernel kernel-core` resolves against Fedora too, where
#    7.2.8-200 is newer than the OGC build, and the transaction fails with
#    "cannot install both kernel-7.2.8-ogc1.1.fc44 and kernel-7.2.8-200.fc44".
#    Paths pin the exact file and cannot drift.
#
# Consequence worth stating: this base's tuned initramfs and its
# bootc-generic-growpart service -- which grows the root partition on first boot
# in a VM -- are built for Hummingbird's kernel and do not come with the OGC one.
# A VM may need its disk expanded by the hypervisor instead.
#
# The image digest is read from AKMODS_IMAGE in the Containerfile. A tag would
# move under the build and the kmods in the NVIDIA phase are pinned to the
# kernel inside the same bundle, so a tag bump can pair a kernel with modules
# built for a different one.
###############################################################################

AKMODS_PATH="${AKMODS_PATH:-/akmods-common}"

echo "::group:: Swap in the OGC kernel"

if [[ ! -d "${AKMODS_PATH}/kernel-rpms" ]]; then
	echo "::error::No kernel RPMs at ${AKMODS_PATH}/kernel-rpms; the akmods stage did not land" >&2
	exit 1
fi

# Fail before touching the running kernel if the bundle is not what the NVIDIA
# phase will install against. Discovering this after the swap means an image
# with no bootable kernel.
#
# The kernel version is queried with the architecture appended, because that is
# what the module tree directory is named and what `uname -r` reports:
# /usr/lib/modules/7.2.8-ogc1.1.fc44.x86_64, not ...fc44. Querying
# %{VERSION}-%{RELEASE} alone yields 7.2.8-ogc1.1.fc44, which matches no
# directory and no kernel on the system.
OGC_KERNEL_RPM="$(find "${AKMODS_PATH}/kernel-rpms" -name 'kernel-[0-9]*.rpm' -print -quit)"
OGC_KVER="$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' "${OGC_KERNEL_RPM}")"
echo "OGC kernel: ${OGC_KVER}"

# Record it for the NVIDIA phase, which must install a kmod built for exactly
# this kernel-version-release.
printf '%s\n' "${OGC_KVER}" >/run/ogc-kernel-version

# What the base is currently on, for the record in the build log. Useful when a
# later boot failure turns out to be a stale module tree.
BASE_KVER="$(uname -r)"
echo "Replacing base kernel: ${BASE_KVER}"

# Remove before installing. dnf5 cannot do both in one transaction here: naming
# the old packages alongside the new paths makes Fedora's newer candidate
# eligible, and the transaction fails before anything is removed.
# shellcheck source=/dev/null
source /ctx/build/dnf5-retry.sh
DNF5_RETRY_ATTEMPTS="${DNF5_RETRY_ATTEMPTS:-8}"

# kernel-core pulls in kernel-modules and kernel-uname-r; removing it is enough
# for the rest, but naming them makes the intent explicit and survives a base
# change that stops pulling them.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" remove -y kernel-core kernel-modules kernel-modules-core

# Install the OGC set: kernel, kernel-core, kernel-modules. Deliberately NOT
# kernel-devel or kernel-devel-matched. Those pull gcc, binutils, glibc-devel
# and a C++ toolchain -- 121 packages, roughly 500 MB of build tooling for an
# image that ships no compiler, which is the opposite of what this base is.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y \
	"${AKMODS_PATH}"/kernel-rpms/kernel-[0-9]*.rpm \
	"${AKMODS_PATH}"/kernel-rpms/kernel-core-*.rpm \
	"${AKMODS_PATH}"/kernel-rpms/kernel-modules-*.rpm

# Assert the result rather than trusting the exit status. A transaction can
# succeed and still leave the base kernel in place if something re-satisfied the
# dependency from Fedora, and that produces an image whose kmods cannot load.
installed_kver="$(rpm -q kernel --qf '%{VERSION}-%{RELEASE}.%{ARCH}')"
if [[ "${installed_kver}" != "${OGC_KVER}" ]]; then
	echo "::error::kernel is ${installed_kver}, expected ${OGC_KVER}" >&2
	exit 1
fi
if rpm -q kernel-modules-core >/dev/null 2>&1; then
	echo "::error::kernel-modules-core survived the swap; modules would not match the core" >&2
	exit 1
fi

# Remove the module trees of the kernels that were just removed.
#
# `dnf5 remove` does not clean up after itself here, and the residue is not
# cosmetic. kernel-core's posttrans runs kernel-install and depmod, which write
# modules.dep, modules.alias and the rest into the tree; those files are generated
# rather than packaged, so rpm does not own them and does not remove them. What is
# left is a directory that `rpm -qf` reports as belonging to nothing, holding 45 MB
# of a kernel that is no longer installed.
#
# It matters for more than disk. A module tree for a kernel that is not present is
# what a later kmod install or a depmod run will pick up, and on an ostree system
# nothing else will ever tidy it. Verified on the base: /usr/lib/modules holds
# 7.2.8-200.fc44.x86_64 alongside the OGC tree after the swap.
#
# Scoped to directories whose name is not the installed kernel, so it cannot
# remove the tree that was just installed. Anything not under /usr/lib/modules is
# left alone.
for tree in /usr/lib/modules/*; do
	[[ -d "${tree}" ]] || continue
	[[ "${tree}" == "/usr/lib/modules/${OGC_KVER}" ]] && continue
	echo "Removing orphaned module tree: ${tree#/usr/lib/modules/}"
	rm -rf "${tree}"
done

# Assert the invariant rather than trusting the loop, because a stray tree that
# survived would be very hard to attribute later.
for tree in /usr/lib/modules/*; do
	if [[ -d "${tree}" && "${tree}" != "/usr/lib/modules/${OGC_KVER}" ]]; then
		echo "::error::module tree ${tree} does not belong to the installed kernel" >&2
		exit 1
	fi
done

echo "::endgroup::"

echo "::group:: Ensure an initramfs for the OGC kernel"

# Where it goes is not the usual place, and that is the base's choice rather than
# an accident. Hummingbird runs with /boot empty in the committed image and
# bootupd populating it at first boot, so its own build writes the initramfs to
# /usr/lib/modules/<kver>/initramfs.img and leaves /boot alone:
#
#   dracut -vf /usr/lib/modules/${kver}/initramfs.img ${kver}
#
# This step mounts /boot as tmpfs, so the initramfs the kernel-core package
# ships at /boot/initramfs-<kver>.img is discarded when the layer commits.
# Writing it to the modules directory is what makes it survive, and where
# bootc-image-builder and bootupd expect to find it.
#
# Asserted rather than assumed: a kernel with no initramfs boots to a panic, and
# there is no way to tell that from inside a build.
modules_dir="/usr/lib/modules/${OGC_KVER}"
initramfs="${modules_dir}/initramfs.img"

if [[ ! -d "${modules_dir}" ]]; then
	echo "::error::no module tree at ${modules_dir}" >&2
	exit 1
fi

if [[ ! -f "${initramfs}" ]]; then
	echo "::warning::no initramfs at ${initramfs}; generating with dracut" >&2
	dracut --force --kver "${OGC_KVER}" "${initramfs}"
fi

if [[ ! -f "${initramfs}" ]]; then
	echo "::error::no initramfs at ${initramfs}; this kernel cannot boot" >&2
	exit 1
fi

# depmod must have run against the new tree, or the kmods installed in the next
# phase cannot resolve the kernel's symbol versions. The kernel-modules package
# triggers it, but the tree is new here so it is asserted rather than assumed.
depmod -a "${OGC_KVER}" 2>/dev/null || true
if [[ ! -f "${modules_dir}/modules.dep" ]]; then
	echo "::error::no modules.dep for ${OGC_KVER}; kmods cannot be resolved" >&2
	exit 1
fi

echo "initramfs: ${initramfs}"

echo "::endgroup::"