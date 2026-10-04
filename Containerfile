FROM ghcr.io/projectbluefin/utah-packages@sha256:7a2a67087cac466c3bd42ab47626bfe9303227806895920edce65c0563bf1555 AS packages

FROM ghcr.io/projectbluefin/common:latest@sha256:b7e3487cafe8b21e10bb514f218406548f4c1abef5e444963094cbf2ec60e4b1 AS common
FROM ghcr.io/ublue-os/brew:latest@sha256:bc6f5a9fc4f28cded2fe567b31f74825c1f4481d5e43c537c3fcc0d3df6d22ab AS brew

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
FROM ghcr.io/projectbluefin/utah-nvidia:testing

# Image identity - these define how bootc, fastfetch, and the ublue ecosystem
# recognize your image. Change these to match your project name.
ARG IMAGE_NAME="utahraptor"
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
