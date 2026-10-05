###############################################################################
# PROJECT NAME CONFIGURATION
###############################################################################
# Name: microraptor
#
# The authoritative name at publish time is the repository name: build-image.yml
# derives IMAGE_NAME from ${{ github.event.repository.name }} and pushes the
# GHCR package under it. This value is the fallback for local `just build` and
# the image identity metadata.
#
# Two other files carry the name as a literal: the Justfile's IMAGE_NAME default
# and artifacthub-repo.yml's repositoryID. tests/contract/identity_test.bats
# fails when the three disagree. See "Quick start" in README.md.
###############################################################################

###############################################################################
# MULTI-STAGE BUILD ARCHITECTURE
###############################################################################
# This Containerfile follows the Bluefin architecture pattern as implemented in
# @projectbluefin/distroless. The architecture layers OCI containers together:
#
# 1. Context Stage (ctx) - Combines resources from:
#    - Local build scripts and custom files
#    - @projectbluefin/common - The shared desktop configuration and plumbing
#    - @ublue-os/brew - Homebrew integration
#
# 2. Base Image Options (edit the FROM line below):
#    - `quay.io/hummingbird-community/bootc-os` (Hummingbird, minimal, no desktop)
#    - `quay.io/fedora-ostree-desktops/silverblue` (Fedora, GNOME desktop)
#    - `quay.io/fedora-ostree-desktops/base-main` (Fedora, no desktop)
#    - `quay.io/centos-bootc/centos-bootc:stream10` (CentOS-based)
#
# A base with no Fedora repository of its own needs packages/fedora.repo, which
# this image's Containerfile installs. Hummingbird is the case that motivated
# it; the Fedora desktop bases already enable fedora and fedora-updates.
#
# See: https://docs.projectbluefin.io/contributing/ for architecture diagram
###############################################################################

# OCI package factory. Carries a repository of prebuilt RPMs, bind mounted to
# /etc/utah-packages and read as a file:// dnf5 source.
#
# The FROM is a literal reference, not ${ARG} interpolation, for the same reason
# the akmods and common references are: Buildah does not substitute a global ARG
# into a FROM line here. `FROM ${PACKAGE_IMAGE_REF}` -- with that name never
# defined anywhere -- expanded to nothing, and Buildah then reported
# "no FROM statement found" and failed with exit 125, pointing at the whole
# Containerfile rather than at the one token that was wrong.
#
# Digest only, no tag. This digest is not what :latest currently resolves to
# (:latest is sha256:5577d71e...), so a tag would assert a relationship that does
# not hold. The digest is a single-platform manifest, pulls cleanly, and its root
# holds exactly /repository -- which is the source path both bind mounts name.
#
# The ARGs below are the declared source of truth and the Renovate anchor; the
# FROM, these, and the factory-pin stamp in packages/utah.repo are asserted to
# agree by tests/contract/utah-packages_test.bats. Three copies of a digest with
# no check between them is how the stamp and the reference drift apart.
ARG PACKAGE_IMAGE=ghcr.io/projectbluefin/utah-packages
ARG PACKAGE_IMAGE_SHA=sha256:0f04cff2dd0b085604ff3cd79d538ab14b97cbe356980f7d365a35dfc70c857b

FROM ghcr.io/projectbluefin/utah-packages@sha256:d257e97a0057e37da47995bb142c180e2352960ab13bd44594215616a395b717 AS packages

FROM ghcr.io/projectbluefin/common:latest@sha256:35c638f7aaf6e07d4638a551fe143eb3d955db5159166acf6831479095ec1089 AS common
FROM ghcr.io/ublue-os/brew:latest@sha256:2aaf87e3757466bc28d056505a651c7ca5c56fd28f6ff709b34f3f5dbc860e89 AS brew


# OGC kernel RPMs and the NVIDIA open kmod, from ublue-os/akmods.
#
# Two separate bundles, and they have to come from the same build. Each ships its
# own copy of the kernel RPMs, and a kmod is compiled against one exact
# kernel-version-release -- so pinning only the kmod would let the kernel move
# under it. 30-kernel.sh and 40-nvidia.sh check the two versions against each
# other and fail the build on a mismatch, which is why a bump cannot silently
# produce an unbootable pair.
#
# Written as literal references rather than ${ARG} interpolation, like the
# common and brew lines above. An ARG declared before the first FROM is a global
# ARG, which Buildah does not substitute into a FROM line here: it reports the
# ARG as a stage step and then fails with
# `invalid base image specification "@"`. A literal reference also gives
# Renovate a digest it can match directly.
#
# `nvidia-open` is the open kernel module, which covers RTX 20/30/40/50-series
# and GTX 16-series. Older hardware needs akmods-nvidia (the closed module).
FROM ghcr.io/ublue-os/akmods:ogc-44@sha256:2ca12d5f66793016f98eddc85e167900edc35dbca581fb8b7db9e44945663c73 AS akmods-common
FROM ghcr.io/ublue-os/akmods-nvidia-open:ogc-44@sha256:77ae8a5fa75b9236b46cad24a858916219164586e3f85ba6bdf3d97ef7285f18 AS akmods-nvidia

# Builds the kernel-uname-r shim in a stage that is thrown away.
#
# The kmod requires kernel-uname-r = <the OGC kernel>. That is a synthetic
# provide: Fedora's kernel-core generates it in a scriptlet, the OGC kernel-core
# has no such scriptlet, and nothing in the akmods bundle provides it. Without
# this the kmod cannot resolve and 40-nvidia.sh fails.
#
# rpm-build is a 54-package dependency chain, so it is installed here and never
# in the image. Building it in 40-nvidia.sh would mean gcc and binutils passing
# through a layer of a runtime image -- the opposite of what this base is. The
# result is copied out as a single small RPM and the toolchain disappears with
# the stage.
# Built on Fedora rather than on the image's own base. Both behave the same for
# this spec -- the missing %install/%files problem below was not Hummingbird's --
# but Fedora 44 is where rpm-build is exercised most heavily, so it is the base
# whose packaging behaviour is least likely to surprise. Nothing from this stage
# reaches the image except the one small RPM.
FROM docker.io/library/fedora:44@sha256:43b29f65a41eb9c35e1cd5323e3bdf3b655c2357a9f4f1ff2f9c2798e5045d80 AS shim-build
# Self-contained apart from the one script below: the kernel version it needs
# comes from the same akmods bundle the runtime phases use, so the shim cannot
# describe a kernel other than the one being installed. It needs no repo
# definitions of its own -- this base is plain Fedora and enables its own.
#
# The script is copied in directly rather than through the ctx stage, because ctx
# copies /out from this stage and mounting ctx here would be a dependency cycle.
# It has to be executable for the same reason every other phase script is.
COPY --chmod=755 build/35-kernel-uname-r-shim.sh /build/35-kernel-uname-r-shim.sh
RUN --mount=type=bind,from=akmods-common,source=/,target=/akmods-common,ro \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=tmpfs,dst=/tmp \
    /build/35-kernel-uname-r-shim.sh

# Context stage - combine local and imported OCI container resources
FROM scratch AS ctx

COPY build /build
COPY custom /custom

COPY packages /packages

# Copy from OCI containers to distinct subdirectories to avoid conflicts
COPY --from=common /system_files /oci/common
COPY --from=brew /system_files /oci/brew

# The kernel-uname-r shim, one small RPM. Copied into the context rather than
# bind mounted so 40-nvidia.sh can install it by path the way it installs every
# other RPM, without a second mount on that step.
COPY --from=shim-build /out /out

# Base Image - Hummingbird (Fedora 44 packages, minimal, no desktop)
# Renovate keeps the digest pin below up to date. Do not drop the digest or add
# trailing whitespace: `just build` parses this line for the base tag and the
# base image name, and a malformed line makes it exit rather than guess.
FROM quay.io/hummingbird-community/bootc-os:latest@sha256:fcbd6c30452076312525ca166df9a1f1dbd9f97347a5ad80c52a55cbcd526525

# Image identity - these define how bootc, fastfetch, and the ublue ecosystem
# recognize your image. Change these to match your project name.
ARG IMAGE_NAME="microraptor"
ARG IMAGE_VENDOR="projectbluefin"
ARG UBLUE_IMAGE_TAG="stable"
# Supplied by `just build` from the base image's FROM line.
ARG BASE_IMAGE_NAME=""
ARG VERSION=""
# Hummingbird's os-release reports VERSION_ID="20251124", a build date rather
# than a Fedora release, so 00-image-info.sh cannot derive the Fedora major
# from it. This is the release packages/fedora.repo points at, and it moves
# together with that file. A Fedora-based base needs no ARG here: its
# os-release already answers the question, and the script prefers the explicit
# value only when one is set.
ARG FEDORA_MAJOR_VERSION="44"
# Copr chroot for this base. `dnf5 copr enable` autodetects one from os-release
# and Hummingbird yields hummingbird-20251124-x86_64, which no COPR carries.
# Read by build/copr-helpers.sh. Leave unset on a Fedora base, where
# autodetection is correct.
ENV COPR_CHROOT="fedora-44-x86_64"

### MODIFICATIONS
## Make modifications desired in your image and install packages by modifying the build scripts.
## The following RUN directives mount the ctx stage which includes:
##   - Local build scripts from /build
##   - Local custom files from /custom
##   - Files from @projectbluefin/common at /oci/common (includes branding/artwork content)
##   - Files from @ublue-os/brew at /oci/brew
## Scripts run in the order of the RUN blocks below: image identity, runtime
## overlays, default packages and services, then cleanup. An activated example
## gets its own block between the package phase and the cleanup phase.

RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/00-image-info.sh

### PACKAGE SOURCES
## Hummingbird ships only its own repository, so dnf5 needs both the Fedora
## definitions in packages/ and its own plugin packages before any later phase
## can run a transaction:
##
##   - packages/*.repo go to /etc/yum.repos.d, keys to /etc/pki/rpm-gpg
##   - dnf5-plugins provides the `config-manager`, `versionlock` and `copr`
##     subcommands that 20-packages-and-services.sh and 90-cleanup.sh call
##   - rsync, which 10-overlay.sh uses for every overlay
##   - flatpak, which 10-overlay.sh's units and the Flathub remote need
##
## Terra goes in here rather than in the package phase: the package phase has to
## resolve ghostty from it, and a repository a later step enables is one that
## phase cannot see. 90-cleanup.sh closes it along with fedora.repo.
##
## `config-manager` is itself a plugin subcommand, so dnf5-plugins has to be
## installed before the dnf settings can be set at all.
##
## The install goes through dnf5_retry, which is not papering over a
## misconfiguration. The mirrors return 404 for a fraction of .rpm requests
## through no fault of this setup -- measured at roughly one in three, on a
## different package each time -- so a build that runs once fails
## intermittently for reasons unrelated to what it is building. The retry wraps
## the transaction rather than warming the metadata cache first, because it is
## the .rpm download that 404s; `--setopt=retries=N` does not cover it either,
## since that retries one request against one mirror and a mirror answering 404
## has nothing to retry. build/dnf5-retry.sh carries the full reasoning.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=packages,source=/repository,target=/etc/utah-packages,ro \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    install -d -m0755 /etc/yum.repos.d /etc/pki/rpm-gpg \
    && install -m0644 /ctx/packages/fedora.repo /ctx/packages/terra.repo /ctx/packages/utah.repo /etc/yum.repos.d/ \
    && install -m0644 /ctx/packages/RPM-GPG-KEY-fedora-44-primary /etc/pki/rpm-gpg/ \
    && . /ctx/build/dnf5-retry.sh \
    # 12 rather than the usual 8. This is the first transaction in the build and
    # the one that downloads the most packages, so it has the most chances to hit
    # the mirror flake -- and a failure here costs the whole build, because every
    # later phase runs in the same RUN chain.
    #
    # The flake is not steady-state bad: measured on this network, the same URL
    # returns 200 and 404 within seconds of itself, so windows of seconds-long
    # and minutes-long failure both occur. A sustained window is what exhausts a
    # small attempt count, and a longer one rides it out at the cost of a slower
    # genuine failure. Genuine failures still fail -- see dnf5-retry.sh.
    && dnf5_retry 12 install -y dnf5-plugins rsync flatpak \
    && dnf5 config-manager setopt keepcache=1 install_weak_deps=0

### RUNTIME OVERLAYS
## Overlays Common's shared runtime layer and the Brew integration files, then
## copies the template's custom declarations (Brewfiles, ujust recipes, Flatpak
## preinstalls, /etc/skel seeds) and enables the units that consume them.
## This phase installs no packages; see the package phase below.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=bind,from=packages,source=/repository,target=/etc/utah-packages,ro \
    --mount=type=cache,dst=/var/cache/rpm-ostree \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/10-overlay.sh

### DEFAULT PACKAGES AND SERVICES
## Installs the image's default RPM and COPR packages and enables the services
## they provide. Packages live here, not in the overlay phase, so overlay edits
## cannot invalidate the package layer.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=bind,from=packages,source=/repository,target=/etc/utah-packages,ro \
    --mount=type=cache,dst=/var/cache/rpm-ostree \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/20-packages-and-services.sh

### HARDWARE AND SESSION
## WiFi and its firmware, Bluetooth, the polkit agent, file and mount access,
## laptop power and firmware management, and the bash completion wiring.
##
## After the desktop packages because it is a separate concern with a separate
## kind of justification, and before the kernel phase because the firmware
## packages land in the same transaction sequence as everything else.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=cache,dst=/var/cache/rpm-ostree \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/25-hardware-and-session.sh

### OGC KERNEL
## Swaps Hummingbird's kernel for the Open Gaming Collective build the akmods
## kmods are compiled against. Bind mounted rather than copied: the bundle is
## ~150 MB of RPMs that must not ship in the image, and a COPY would leave them
## in a layer unless something removed them afterwards.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=akmods-common,source=/,target=/akmods-common,ro \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/30-kernel.sh

### NVIDIA
## The open kernel module, plus the userspace driver. Split from the kernel phase
## so either can be reverted on its own: delete this RUN block and 40-nvidia.sh
## to drop back to a plain OGC kernel, or delete both to return to Hummingbird's
## own kernel entirely.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=bind,from=akmods-nvidia,source=/,target=/akmods-nvidia,ro \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/40-nvidia.sh

### CLEANUP
## Finalises package and Flatpak sources, then prunes build artifacts before
## linting. /run is deliberately not mounted as tmpfs here: the script must
## remove image-layer files such as /run/dnf so bootc lint's nonempty-run-tmp
## check passes. It tolerates busy Buildah bind mounts while clearing contents.
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=tmpfs,dst=/tmp \
    --mount=type=tmpfs,dst=/boot \
    /ctx/build/90-cleanup.sh

### /opt
## Makes /opt writeable by default. Needs to be here to make the main image
## build strict (no /opt there). This is for downstream images/stuff like k0s.
## If you need /opt as an immutable real directory for build-time packages
## (e.g. google-chrome, docker-desktop), replace the next line with:
##   RUN rm /opt && mkdir /opt
RUN rm -rf /opt && ln -s /var/opt /opt

### IMAGE METADATA
## The Containerfile owns the metadata schema baked into every image. Local
## builds and CI supply the dynamic values through `just build`; keeping these
## ARGs late prevents a new version or timestamp from invalidating package and
## overlay layers above.
ARG IMAGE_DESC="My Customized Universal Blue Image"
ARG IMAGE_CREATED=""
ARG IMAGE_LOGO_URL="https://avatars.githubusercontent.com/u/120078124?s=200&v=4"
ARG IMAGE_KEYWORDS="bootc,ublue,universal-blue"
ARG IMAGE_REF="main"
## The commit the image was built from. It is declared here, with the other
## volatile metadata, so a new commit only invalidates the label layer.
## Declaring it before 00-image-info.sh would invalidate the package and overlay
## layers on every commit, which is why os-release does not carry it.
ARG SHA_HEAD_SHORT=""

LABEL org.opencontainers.image.title="${IMAGE_NAME}" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${SHA_HEAD_SHORT}" \
      org.opencontainers.image.description="${IMAGE_DESC}" \
      org.opencontainers.image.source="https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}/blob/${IMAGE_REF}/Containerfile" \
      org.opencontainers.image.url="https://github.com/${IMAGE_VENDOR}/${IMAGE_NAME}" \
      org.opencontainers.image.vendor="${IMAGE_VENDOR}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      io.artifacthub.package.readme-url="https://raw.githubusercontent.com/${IMAGE_VENDOR}/${IMAGE_NAME}/refs/heads/main/README.md" \
      io.artifacthub.package.logo-url="${IMAGE_LOGO_URL}" \
      io.artifacthub.package.keywords="${IMAGE_KEYWORDS}" \
      io.artifacthub.package.license="Apache-2.0" \
      io.artifacthub.package.deprecated="false" \
      containers.bootc="1"

### INIT
## Required for bootc images
CMD ["/sbin/init"]

### LINTING
## Verify final image and contents are correct. --fatal-warnings catches issues.
## RUN bootc container lint --fatal-warnings
