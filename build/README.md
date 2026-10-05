# Build scripts

Scripts that run during image assembly. The Containerfile names each one in its
own `RUN` block, so the order is whatever the Containerfile says — there is no
prefix auto-discovery. The numbers communicate intent.

## Phases

| Script | Does |
|---|---|
| `00-image-info.sh` | Writes the image identity into `os-release` and `image-info.json`: the base image name, the Fedora major derived from the base's `os-release`, the version string, and the tag. |
| `10-overlay.sh` | Overlays `projectbluefin/common`'s shared layer and the Brew integration, copies this template's declarations (Brewfiles, ujust recipes, Flatpak preinstalls, `/etc/skel` seeds), and enables the units that consume them. Installs no packages. |
| `20-packages-and-services.sh` | Installs the default RPM and COPR packages and enables their services. Packages live here, not in the overlay phase, so an overlay edit cannot invalidate the package layer. Also installs Voxtype from a pinned release-URL RPM — see below. |
| `25-hardware-and-session.sh` | WiFi and the Intel firmware it needs, Bluetooth, the polkit agent, GVFS and XDG, laptop power and firmware management, and the bash completion wiring. Separate from 20 because the justification is per-package — a reader asking why the firmware is 147 MB wants a different answer than one checking whether `just` is installed. |
| `90-cleanup.sh` | Finalises package and Flatpak sources, prunes build artifacts, and prepares for `bootc container lint`. |

Helpers, not phases: `copr-helpers.sh` (sourced), `validate-brewfiles.sh`, and
`validate-flatpaks.sh` (called by the Justfile and CI).

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
