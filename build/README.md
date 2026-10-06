# Build scripts

Scripts that run during image assembly. The Containerfile names each one in its
own `RUN` block, so the order is whatever the Containerfile says — there is no
prefix auto-discovery. The numbers communicate intent.

## Phases

| Script | Does |
|---|---|
| `00-image-info.sh` | Writes the image identity into `os-release` and `image-info.json`: the base image name, the Fedora major derived from the base's `os-release`, the version string, and the tag. Shared by both images. |
| `10-overlay.sh` | Overlays `projectbluefin/common`'s shared layer and the Brew integration, copies this template's declarations (Brewfiles, ujust recipes, Flatpak preinstalls, `/etc/skel` seeds), and enables the units that consume them. Installs no packages. **Workstation only.** |
| `20-packages-and-services.sh` | Installs the default RPM and COPR packages and enables their services. Packages live here, not in the overlay phase, so an overlay edit cannot invalidate the package layer. Also installs Voxtype from a pinned release-URL RPM — see below. **Workstation only.** |
| `20-server-base.sh` | The homelab image's server baseline, tailscale, and fail2ban. Replaces `20-packages-and-services.sh` there: no display manager, no compositor, no terminal. **Homelab only.** |
| `25-hardware-and-session.sh` | WiFi and the Intel firmware it needs, Bluetooth, the polkit agent, GVFS and XDG, laptop power and firmware management, and the bash completion wiring. Separate from 20 because the justification is per-package — a reader asking why the firmware is 147 MB wants a different answer than one checking whether `just` is installed. **Workstation only.** |
| `25-server-network.sh` | The homelab image's WiFi stack (identical package set to the workstation's), sshd, and key-only authentication. Replaces `25-hardware-and-session.sh` there: the polkit and XDG session plumbing has no session to serve. **Homelab only.** |
| `30-k0s.sh` | The k0s binary from a pinned release, plus the controller and worker units. Neither is enabled. **Homelab only.** |
| `35-kc-agent.sh` | The KubeStellar Console agent from a pinned nightly, plus a preset-enabled unit conditioned on a kubeconfig existing. **Homelab only.** |
| `90-cleanup.sh` | Finalises package and Flatpak sources, prunes build artifacts, and prepares for `bootc container lint`. Shared by both images. |

Helpers, not phases: `copr-helpers.sh` (sourced), `validate-brewfiles.sh`, and
`validate-flatpaks.sh` (called by the Justfile and CI).

## Two images

This repository builds two. The **workstation** image is `Containerfile.workstation`
and is still published as plain `microraptor`; the **homelab** image is
`Containerfile.homelab` and is published as `microraptor-homelab`.

```bash
just build-workstation    # or just build — workstation is the default
just build-homelab
```

The flavour is the third argument to `build` and names the Containerfile:
`Containerfile.<flavor>`. It is passed with `-f` rather than left to podman,
because `podman build .` with no `-f` looks for a file literally called
`Containerfile` and there is no longer one.

### What is shared and what is not

Shared: the base image and its digest, `00-image-info.sh`, `90-cleanup.sh`, and
the `copr-helpers.sh` / `dnf5-retry.sh` helpers.

`90-cleanup.sh` is shared unchanged, and it is safe on the homelab image because
every part of it is guarded: the Flatpak group tests for its unit before touching
it, `rpm-ostreed-automatic.timer` is disabled with `|| true`, and the repository
list already names `tailscale.repo` — which is one of the reasons tailscale can
be installed there without teaching the cleanup phase anything new.

Not shared, and this is the reason there is a second Containerfile rather than a
conditional in the first: the workstation image's desktop overlay, its package
phase, its session phase, and its kernel and NVIDIA phases have no counterpart
on a server. A reader asking "why is there no display manager here?" gets a
different answer than one asking "why is there no k0s?".

### The homelab image's k0s

k0s is a Kubernetes distribution in one static binary — apiserver, etcd, kubelet,
kube-proxy, containerd and the scheduler are all inside it, and `k0s controller`
starts a cluster from that file. **263 MB installed**, which is the largest
single thing in either image and is stated here rather than left to a build log.

It is k0s rather than kubeadm because kubeadm, kubelet and kubectl **have no
Fedora package at all** — `src.fedoraproject.org/rpms/kubeadm` does not exist, and
only cri-o is packaged. Using kubeadm would mean enabling `pkgs.k8s.io`, which
has to stay enabled on every node for the life of the cluster so that kubelet can
be updated. That is a third-party repository shipped live on every node in a
cluster, which is the outcome `90-cleanup.sh` exists to prevent.

Neither k0s unit is enabled. A node is a controller or a worker by decision, not
by image, and the two units are made mutually exclusive by a token file:
`k0scontroller.service` requires `/etc/k0s/token` **not** to exist and
`k0sworker.service` requires it to. That is what keeps two nodes from both
claiming to be the control plane. Arguments live in `/etc/sysconfig/k0s`, not in
the units, so turning a single-node image into a cluster is an edit rather than an
image rebuild.

### The homelab image's KubeStellar console

`kc-agent` is installed from a **pinned nightly**, and there is no stable release
to pin: every tag in `kubestellar/console` is `vX.Y.Z-nightly.DATE` and is marked
prerelease. `build/35-kc-agent.sh` carries a large comment at the pin saying so,
including how to bump it and where to recompute the digest.

This was a deliberate trade. The alternative is leaving kc-agent to Homebrew via
the `kubestellar/tap` — which is how `projectbluefin/server` consumes it — and
that tracks upstream automatically but leaves the console absent until a user
runs `brew`. Pinning it means the console is there on first boot and that the
image carries a prerelease upstream will never patch.

Two related upstream facts worth knowing before expecting the full console:

- The `kubestellar` CLI is **not** in the KubeStellar v0.30.0 release tarball.
  That archive ships `controller-manager`, `ocm-transport-controller` and
  `kflex-get-kubeconfig` only, so the `kubestellar create` bootstrap path is not
  available from release artifacts. The console here is kc-agent against a k0s
  cluster, not a KubeFlex control plane.
- `projectbluefin/server` does not ship the console as a binary at all. Its
  `kubestellar-sysext` deploys the console as OCI container images behind a
  Gateway with a generated login, version-locked to the OS image — a
  bootstream-built sysext that a Containerfile cannot pin the same way.

### Updates are deliberately not automatic

The homelab image installs `uupd` and does not enable `uupd.timer`. Every node in
a cluster runs the same update policy at the same time, and uupd applies a
pending update and reboots — so a three-node cluster would reboot itself in
unison and lose quorum. Rolling a cluster is an operator's deliberate,
one-node-at-a-time job. `systemctl enable uupd.timer` opts a node in.

`tailscaled` is likewise installed but not enabled: it starts and holds no auth
key until a person runs `tailscale up`.

## Package sources

`packages/` holds the repository definitions and GPG keys the Containerfile
installs before the first transaction. It exists because Hummingbird ships only
its own repository, so a Fedora package is not installable until `fedora.repo` is
in place. A Fedora desktop base enables `fedora` and `fedora-updates` itself and
does not need any of it.

Two things there are load-bearing rather than documentation:

- **`zchunk=false`** in `fedora.repo`. Fedora stopped publishing the `.xml.zck`
  variants dnf5 asks for by default, and without it every metadata fetch 404s.
- **The digest and the `FEDORA_MAJOR_VERSION` ARG move together.** The ARG exists
  because Hummingbird's `os-release` reports `VERSION_ID="20251124"`, a build
  date, and `00-image-info.sh` cannot read a Fedora major from it.

`hummingbird.repo` and `nvidia-container.repo` are reference copies, not
installed. Hummingbird already ships a working definition of its own repository,
with the signing key in the rpmdb; the copy here records why it is safe
(`gpgcheck=1`, `priority=10`) without narrowing it to one architecture.

`terra.repo` **is** installed, and is the one repository here with
`gpgcheck=0`. Terra publishes no key at a stable URL — `RPM-GPG-KEY-terra` 404s,
and `terra-release`, the package that would carry it, lives only inside Terra
itself. That is a bootstrap cycle with nothing to verify against, so the key
check is off and `90-cleanup.sh` closes the repository before the image is
committed. Note the baseurl is spelled with a literal `44`, not `$releasever`:
this base's `VERSION_ID` is a build date, so `$releasever` would expand to
`20251124` and 404.

## A package with no repository

Voxtype is installed from a URL, not from a repository. Upstream ships a release
RPM and nothing a distro could repackage: no Fedora package, no Terra package, no
COPR, no Flathub build. Every other package in the phase gets its integrity from
repository metadata and a GPG key the Containerfile installed; this one has
neither, so the script has to supply both jobs itself:

- **A version in the URL and a sha256 beside it.** Derived from one variable, so
  they cannot disagree about which version is meant. Only the digest has to be
  recomputed on a bump.
- **The digest is checked before the install, not after.** dnf5 unpacks the
  payload as it installs, so a check that ran afterwards would be reporting on
  bytes already written to the image.
- **`--nogpgcheck`, because the RPM is unsigned.** `rpm -Kv` reports
  `Signature: (none)`. That flag turns off a check that has nothing to check; it
  is not a substitute for the digest.
- **A looped fetch.** The release asset 302s to a CDN host that intermittently
  404s — the same failure `dnf5_retry` exists for. curl's `--retry` does not
  cover it, because it retries one request against one URL with no host to fail
  over to.
- **`curl` installed explicitly.** It is what fetches the RPM, so leaving it to
  the RPM's own dependency on it is circular.

`/tmp` is mounted as tmpfs for this phase, so the 357 MB download never lands in
an image layer.

The general shape — pin the URL, pin the digest, verify before install — is what
to reach for next time a package has no repository. Verify the digest from the
upstream artifact directly:

```bash
curl -fsSL <url> | sha256sum
```

## A COPR that enables nothing

`dnf5 copr enable <project>` without an explicit chroot autodetects one from
the base's `os-release`. On a base whose `VERSION_ID` is not a Fedora release —
Hummingbird reports `20251124` — it resolves to `hummingbird-20251124-x86_64`,
which no COPR carries. The command then **exits zero, writes no repo file, and
installs nothing**, and the only symptom is a later
`No match for argument: <package>`.

`copr-helpers.sh` reads `COPR_CHROOT` for this. The Containerfile sets it; a
base whose `os-release` reports a real release leaves it unset and gets working
autodetection.

`90-cleanup.sh` flips `fedora.repo` to `enabled=0`. Fedora is a build-time source
only, so an installed system resolves just the base's own rebuilt RPMs.

## Examples

Inactive until you activate them:

- `30-tailscale.sh.example` — a third-party RPM repository done safely
- `40-gnome-extensions.sh.example` — GNOME Shell extensions with a dconf override
- `50-nvidia.sh.example` — NVIDIA drivers and CDI container support
- `60-desktop-swap.sh.example` — replacing the GNOME desktop

To activate one, rename it off `.example` and add a `RUN` block to the
Containerfile after the package phase and before the cleanup phase. Copy the
shape below and substitute your script's path:

```dockerfile
RUN --mount=type=bind,from=ctx,source=/,target=/ctx \
    --mount=type=cache,dst=/var/cache/libdnf5 \
    --mount=type=cache,dst=/var/cache/rpm-ostree \
    --mount=type=tmpfs,dst=/boot \
    --mount=type=tmpfs,dst=/tmp \
    /ctx/build/NN-example.sh
```

Deactivating is the reverse: delete the block, rename the file back.

## Writing one

```bash
#!/usr/bin/env bash
set -euo pipefail

dnf5 install -y package-name
```

- Scripts run as root, with the build context at `/ctx`.
- Use `dnf5`, never `dnf` or `yum`, and always `-y`.
- Disable any repository you enable. `copr_install_isolated` does it for COPRs.
- Keep one purpose per script, and name it for that purpose.
