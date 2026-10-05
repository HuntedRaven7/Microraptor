#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Builds the kernel-uname-r shim
#
# Runs in the Containerfile's shim-build stage, which is thrown away. It exists
# so that rpm-build never touches the image.
#
# The problem it solves: the NVIDIA kmod requires
#
#   kernel-uname-r = 7.2.8-ogc1.1.fc44.x86_64
#
# That is a synthetic provide. Fedora's kernel-core generates it in a scriptlet;
# the OGC kernel-core has no such scriptlet, and nothing in the akmods bundle
# provides it. Without it the kmod cannot resolve, and 40-nvidia.sh fails on a
# dependency that no real package will ever satisfy.
#
# rpm-build is a 54-package toolchain chain. Installing it in 40-nvidia.sh would
# put gcc and binutils through a layer of a runtime image, which is the opposite
# of what this base is. Building here and copying one small RPM out is the same
# pattern projectbluefin/utah uses for its kernel.
#
# The kernel version is read from the same akmods bundle the runtime phases use,
# so the shim cannot describe a kernel other than the one being installed. This
# stage cannot mount the build context, because the context copies its output
# from here -- that would be a dependency cycle -- so it reads what it needs from
# the bundle instead.
###############################################################################

AKMODS_PATH="${AKMODS_PATH:-/akmods-common}"
OUT_DIR="${OUT_DIR:-/out}"

echo "::group:: Build the kernel-uname-r shim"

kernel_rpm="$(find "${AKMODS_PATH}/kernel-rpms" -name 'kernel-[0-9]*.rpm' -print -quit)"
if [[ -z "${kernel_rpm}" ]]; then
	echo "::error::no kernel RPM in ${AKMODS_PATH}/kernel-rpms" >&2
	exit 1
fi

# %{%VERSION}-%{RELEASE}.%{ARCH}, not %{%VERSION}-%{RELEASE}: the module tree
# directory and uname -r both carry the architecture.
kver="$(rpm -qp --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' "${kernel_rpm}")"
echo "Kernel the shim will describe: ${kver}"

# The same mirror-flake retry as the rest of the build; see dnf5-retry.sh.
for attempt in 1 2 3 4 5 6 7 8; do
	if dnf5 -q makecache --refresh; then
		break
	fi
	echo "::warning::makecache failed (attempt ${attempt}/8); retrying" >&2
	sleep $((attempt * 5))
done

# The install needs the same treatment as makecache, and for the same reason:
# rpm-build's dependency chain is 54 packages and it is Fedora-provided, so a
# single 404 anywhere in it fails the whole thing. A warmed metadata cache does
# not help -- it is the .rpm download that 404s.
#
# dnf5_retry lives in the build tree, which this stage cannot mount without a
# dependency cycle, so the loop is inlined here. It is short enough that
# duplicating it beats restructuring the stage graph for it.
for attempt in 1 2 3 4 5 6 7 8; do
	if dnf5 install -y rpm-build; then
		break
	fi
	if ((attempt == 8)); then
		echo "::error::rpm-build failed after ${attempt} attempts" >&2
		exit 1
	fi
	echo "::warning::rpm-build install failed (attempt ${attempt}/8); retrying" >&2
	sleep $((attempt * 5))
done

topdir="$(mktemp -d)"
mkdir -p "${topdir}"/{BUILD,RPMS,SRPMS,SPECS,SOURCES}

# %global _build_id_links none stops %_build_id expanding through
# brp-mangle-shebangs, which rpm-build does not pull in and which a package with
# no scripts has no use for. Without it the build fails inside the macro
# expansion rather than at anything this script did.
# %description is mandatory: rpmbuild refuses to parse a spec without one, and
# the error it gives ("parsing failed") does not say which line is missing.
# %changelog is left empty deliberately -- an entry with no date trips
# %source_date_epoch_from_changelog, which is a warning here but makes the build
# non-reproducible, and this package has no history worth recording.
cat >"${topdir}/SPECS/kernel-uname-r.spec" <<SPEC
%global _build_id_links none
Name:           kernel-uname-r
Version:        1
Release:        1
Summary:        Synthetic provider for kernel-uname-r
License:        MIT
BuildArch:      noarch
Provides:       kernel-uname-r = ${kver}
Provides:       kernel-core-uname-r = ${kver}

%description
Satisfies the kernel-uname-r dependency that kmod packages carry.

Fedora's kernel-core generates a kernel-uname-r provide in a scriptlet. The OGC
kernel-core has no such scriptlet, so nothing in the image provides the capability
and kmod-nvidia cannot resolve. This package exists only to carry the provide.

Built at image build time from the kernel RPM in the same akmods bundle the image
installs, so it cannot describe a different kernel.

%install
# %install and %files are both required, and rpmbuild does not say so: a spec with
# neither has nothing to package, so it writes no RPM at all, prints no error, and
# exits 0. That is the whole reason this step appears to succeed while producing
# nothing. A package has to own at least one file to exist.
mkdir -p %{buildroot}%{_datadir}/kernel-uname-r
# The marker names the kernel this shim was built for, so the file on disk records
# which kernel it belongs to rather than being an anonymous empty file.
printf '%{version}-%{release}\n' > %{buildroot}%{_datadir}/kernel-uname-r/built-for

%files
%{_datadir}/kernel-uname-r

%changelog
# Intentionally empty. %source_date_epoch_from_changelog warns about it, and the
# warning is accurate -- there is no history here to record, and this package is
# rebuilt from scratch on every build rather than released over time.
SPEC

rpmbuild --define "_topdir ${topdir}" -bb "${topdir}/SPECS/kernel-uname-r.spec" >/dev/null

mkdir -p "${OUT_DIR}"
shim="$(find "${topdir}/RPMS" -name 'kernel-uname-r-*.rpm' -print -quit)"
if [[ -z "${shim}" ]]; then
	echo "::error::rpmbuild produced no kernel-uname-r RPM" >&2
	exit 1
fi
install -m0644 "${shim}" "${OUT_DIR}/"
rm -rf "${topdir}"

echo "::endgroup::"

echo "Wrote ${OUT_DIR}/$(basename "${shim}")"
# Prove the provide is actually in there. A shim that built but does not carry
# the capability would fail much later, inside the runtime phase, as a
# dependency error that points nowhere near this stage.
rpm -qp --provides "${OUT_DIR}/$(basename "${shim}")" | grep -qx "kernel-uname-r = ${kver}" || {
	echo "::error::shim does not provide kernel-uname-r = ${kver}" >&2
	exit 1
}
echo "Verified: provides kernel-uname-r = ${kver}"