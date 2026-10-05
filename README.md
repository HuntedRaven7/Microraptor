# microraptor

A template for building your own bootc operating system image, assembled the
same way Bluefin, Aurora, and Bluefin LTS are: from shared OCI layers rather
than by modifying an existing image. The desktop configuration comes from
[`projectbluefin/common`](https://github.com/projectbluefin/common), Homebrew
from [`ublue-os/brew`](https://github.com/ublue-os/brew), and the rest is yours.

It is built to be driven by hand or by an agent.

> Be the one who moves, not the one who is moved.

## What Makes this Raptor Different?

This image is based on
[Hummingbird](https://gitlab.com/redhat/hummingbird/containers) and includes
these customizations.

### Added Packages (Build-time)

- `dnf5-plugins`, `rsync`, `flatpak` — Hummingbird ships none of these, and the
  overlay and package phases need all three
- `just`, `gum`, `fzf`, `jq` — the `ujust` entry point and its helpers
- `uupd` — scheduled update policy, from the `ublue-os/packages` COPR
- `mangowm` — the Wayland compositor, from [Terra](https://repos.fyralabs.com/terra44)
- `sddm` — the display manager, from Fedora 44
- `tailscale` — from Fedora 44
- `ghostty` — from Terra
- `pipewire`, `wireplumber`, `xdg-desktop-portal` — the audio and portal stack,
  from Fedora 44
- The **OGC kernel** (`7.2.8-ogc1.1.fc44`) and the **NVIDIA open kernel module**,
  from `ublue-os/akmods` — see [Kernel and GPU](#kernel-and-gpu)

Also installed, in `build/25-hardware-and-session.sh`:

- `NetworkManager-wifi`, `wpa_supplicant`, `iw` — WiFi
- `iwlwifi-{mvm,mld,dvm}-firmware` — Intel WiFi firmware, ~147 MB
- `bluez`, `bluez-tools` — Bluetooth
- `lxpolkit` — the password-prompt agent
- `gvfs`, `gvfs-mtp` — file manager and phone access
- `xdg-utils`, `xdg-user-dirs` — file type handling and `~/Documents`
- `power-profiles-daemon`, `upower`, `fwupd` — laptop power, battery, firmware
  updates
- `bash-completion` — see [Completions](#completions)

### WiFi firmware

**The base already has `linux-firmware` installed and it contains no WiFi
firmware.** That package is 1848 files and exactly one of them mentions
iwlwifi — the licence. In Fedora 44 the vendor blobs are separate packages and
none was pulled in, so the adapter is visible in hardware and never associates.
This is the single most surprising thing about adding WiFi to this base, and the
reason the firmware assertion in the build checks for blobs on disk rather than
for the package being installed.

All three Intel packages are installed, not one, because which applies depends
on the card and a wrong guess means no network with no error message:

| Package | Size | Covers |
|---|---|---|
| `iwlwifi-mvm-firmware` | 98 MB | modern Intel — AX200/AX210/AX300, BE, 6E |
| `iwlwifi-mld-firmware` | 35 MB | the MLD variants (AX210+, BE200) |
| `iwlwifi-dvm-firmware` | 14 MB | legacy cards predating the mvm driver |

For other hardware, one line changes: `realtek-firmware` (7 MB),
`brcmfmac-firmware` (10 MB) for Broadcom, or `mediatek-firmware` (5 MB).

`NetworkManager-wifi` ships **no systemd unit** — NetworkManager loads the plugin
itself — so there is nothing to enable. The phase checks each unit exists before
enabling it, because `systemctl enable` on a unit that is not installed fails the
build and the set of units moves between releases.

### Completions

`bash-completion` is installed and its hook is wired into `/etc/bashrc`, not
left where the package puts it.

The package's own hook is `/etc/profile.d/bash_completion.sh`, and only a **login
shell** reads `/etc/profile`. A terminal emulator starts a non-login interactive
shell, which reads `~/.bashrc` and nothing else. So the package on its own gives
you an image where completions work over `ssh` and are missing in every window on
the desktop. `/etc/skel/.bashrc` sources `/etc/bashrc` on the way in, so one
guarded block there covers every interactive shell for every new account and for
root — 131 completions, verified in the build.

The block is **appended** with a marker, never written through `custom/files/`:
that would freeze the distro's `bashrc` for the life of the image and silently
lose every future fix to it.

If you manage `~/.bashrc` with chezmoi, keep the `/etc/bashrc` line or source it
from your own — otherwise your dotfiles replace the skel that pulls it in.

### Kernel and GPU

The base ships Hummingbird's `7.2.7-200.fc44` kernel. This image replaces it with
the Open Gaming Collective build so the NVIDIA kmod has something to match —
a kmod is compiled against one exact kernel-version-release, so the two cannot
differ.

That comes from two `ublue-os/akmods` bundles, digest-pinned. They have to move
together: each ships its own copy of the kernel RPMs, so bumping one alone pairs
a kernel with modules built for a different one. `build/30-kernel.sh` and
`build/40-nvidia.sh` record the kernel version and check the kmod against it, and
fail the build on a mismatch — the failure would otherwise only appear at boot,
on hardware the build never touches.

The open module covers RTX 20/30/40/50-series and GTX 16-series. Older hardware
(10-series, 9-series, Quadro P-series) needs the closed module from
`akmods-nvidia` instead, which is a different bundle and tag.

**Two things this costs you.** Hummingbird's tuned initramfs and its
`bootc-generic-growpart` service — which grows the root partition on first boot
in a VM — are built for the base kernel and do not come with the OGC one, so a
VM may need its disk expanded by the hypervisor. And no i686 multilib is
installed, which is the same constraint that keeps Steam out. The akmods bundle
ships 32-bit driver packages that would drag that stack back in, so
`40-nvidia.sh` filters the bundle by architecture rather than globbing it.

Driver updates do not come from a package repository. The kernel module is a
pinned OCI bundle, so the driver moves when the akmods digest does.

#### The `kernel-uname-r` shim

`kmod-nvidia` requires `kernel-uname-r = <the exact kernel>`. Fedora's
`kernel-core` generates that provide in a scriptlet; the OGC `kernel-core` has
no such scriptlet, and nothing in the bundle provides it, so the kmod cannot
resolve. A small noarch RPM carrying exactly that provide is built during the
image build, in a throwaway `shim-build` stage — `rpm-build` is a 54-package
toolchain that should never pass through a layer of a runtime image. The
Containerfile's `shim-build` stage reads the kernel version from the same bundle
the runtime phases install, so the shim cannot describe a different kernel.

#### The NEGATIVO17 repository

`nvidia-driver-selinux` is in neither the akmods bundle nor Fedora 44. It comes
from [negativo17](https://negativo17.org/repos/nvidia/), whose repository
definition ships inside `ublue-os-nvidia-addons` — which is why that package is
installed unconditionally rather than only for Secure Boot signing as its name
suggests. Two corrections are needed before the repository is usable, both
invisible in the failure: its files interpolate `$releasever`, which on this base
expands to a date string rather than a Fedora version, so every baseurl 404s and
`dnf5` reports an enabled repository holding zero packages; and the files ship
disabled. `40-nvidia.sh` fixes the version, enables the repository, and then
asserts it actually resolves packages.

`nvidia-container-toolkit.repo` and the `fedora-nvidia-lts` (closed driver) repo
are deliberately left disabled. The first is for GPU access from containers,
which this image does not set up; the second would conflict with the open module.

To drop either half: delete `40-nvidia.sh` and its `RUN` block to keep the OGC
kernel without the GPU driver, or delete both phases to return to Hummingbird's
own kernel.

### Not installed

- **Steam.** It is available in Terra and does resolve, but installing it pulls
  32-bit libraries that need Fedora's `openssl-libs`, and Hummingbird pins its
  own rebuilt `3.5.8-0.1.hum1` through `openssl-fips-provider-upstream`. dnf5
  refuses the transaction rather than silently dropping packages. A working
  Steam needs a container-toolbox-style chroot or a Fedora base.

### Added Applications (Runtime)

- **CLI tools (Homebrew)**: list them
- **GUI apps (Flatpak)**: list them

### Removed or Disabled

- The Fedora and Terra repositories are enabled for the build and disabled by
  `90-cleanup.sh`. Hummingbird carries no Fedora repo of its own, so the build
  cannot install anything without `packages/fedora.repo` — but an installed
  system resolves only Hummingbird's rebuilt RPMs, so a user cannot install a
  Fedora package that was never part of this image's tested buildroot.
  Every COPR is enabled and disabled inside a single transaction, so no
  third-party repo file ships enabled either.

### Configuration Changes

- The ujust entry point, Homebrew, Flatpak preinstalls, and the setup hooks from
  `projectbluefin/common`'s shared layer
- `uupd.timer` and `uupd-resume.timer` enabled; `rpm-ostreed-automatic.timer`
  disabled where the base has one
- `sddm.service` and `tailscaled.service` enabled

### Desktop configuration is not included

This image ships the compositor, the display manager and the session file those
packages provide. It ships **no MangoWM configuration** — no `mangorc`, no
`mangowmrc`, and nothing else session-specific.

That means SDDM comes up with a session that exits immediately until you supply
one. Write a `mangorc`, or point a `/usr/share/wayland-sessions/*.desktop` entry
at your own entrypoint, or use `chezmoi` from the Brewfile to manage it.
Everything in the `dots` repository is yours to bring across.

_Last updated: 2026-10-02_

> This section is what tells your users how your image differs from its base.
> Update it whenever you add or remove a package, app, or service.

## Quick start

1. **Create your repository** — "Use this template" on GitHub.
2. **Rename the project.** The published name is your repository name. Three
   files carry it as a literal, and `just test-contract` fails if they disagree:

   - `Containerfile` — the `# Name:` comment and `ARG IMAGE_NAME`
   - `Justfile` — the `IMAGE_NAME` default
   - `artifacthub-repo.yml` — `repositoryID`

   Grep for `microraptor` afterwards to catch the prose and the examples.
3. **Finish setup.** [The `onboarding` skill](.agents/skills/onboarding/SKILL.md)
   carries the rest — enabling Actions, auto-merge and workflow permissions, the
   Renovate token, the `stable` branch, branch protection on both branches, and
   the labels. Every step has a `gh` command and a GitHub-website route, and the
   skill ends by auditing that each setting matches.

## What's included

**Build system**

- A build on every push to `main`, publishing `:stable-testing`
- Renovate through `projectbluefin/actions`, updating pinned actions and image
  digests every six hours
- Images older than 90 days pruned automatically
- Pull requests validated for shellcheck, hadolint, Brewfiles, Flatpaks,
  Justfiles, and Renovate config
- Keyless OIDC signing on every published image, enforced at promotion
  ([where the signature is checked](#where-the-signature-is-checked))

**Runtime**

- Homebrew, pre-staged at build time and unpacked on first boot
- Flatpaks declared in `custom/flatpaks/`, installed on first boot
- `ujust` shortcuts for the Brewfiles and for re-applying configuration
- `uupd` for scheduled system updates

## Customize

Pick your base image on the `Containerfile`'s `FROM` line. That line is the only
place the base is chosen: `just build` reads the base tag and the base image name
from it, so it has to stay a single well-formed `FROM …:tag@sha256:…` with no
trailing whitespace. `tests/contract/package-sources_test.bats` enforces that,
because nothing in CI parses the line — CI takes its image name from the event
payload, so a malformed `FROM` breaks local builds only.

A base with no Fedora repository of its own also needs `packages/fedora.repo`,
installed by the Containerfile before the first transaction. Hummingbird is that
case; a Fedora desktop base is not.

`packages/terra.repo` is installed the same way, for `ghostty`.

One trap worth knowing about, because it fails silently: `dnf5 copr enable`
without an explicit chroot autodetects one from the base's `os-release`.
Hummingbird reports `VERSION_ID="20251124"`, which yields a chroot no COPR
carries. The command **exits zero, writes no repo file, and installs nothing** —
the failure surfaces later as `No match for argument: hyprland`. The
Containerfile sets `ENV COPR_CHROOT` for this reason; a base whose `os-release`
reports a real Fedora release does not need it.

Then add to your image:

- **System packages** — `build/20-packages-and-services.sh` ([guide](build/README.md))
- **CLI tools** — `custom/brew/` ([guide](custom/brew/README.md))
- **GUI apps** — `custom/flatpaks/` ([guide](custom/flatpaks/README.md))
- **Commands** — `custom/ujust/` ([guide](custom/ujust/README.md))

[The `customize` skill](.agents/skills/customize/SKILL.md) decides which of
those a given package belongs in.

## Releases

| Branch   | Image tag         | Audience                       |
| -------- | ----------------- | ------------------------------ |
| `main`   | `:stable-testing` | Testers and release candidates |
| `stable` | `:stable`         | Production                     |

Merging to `main` publishes `:stable-testing`; the promotion PR that follows
publishes `:stable` when merged. Promotion verifies the cosign signature on the
testing image before it reports ready, and refuses to promote at all once `main`
has moved past the commit the promotion PR was built from.

> **Known gap:** the promotion gate checks the digest and the signature only. It
> runs no end-to-end tests, so `release/ready` means "signed and unmodified",
> not "functionally validated".

## Image signing

Images are signed with keyless OIDC via Cosign and GitHub Actions. There is no
key to generate or store.

```bash
cosign verify \
  --certificate-identity-regexp="https://github.com/your-username/your-repo-name/.github/workflows/" \
  --certificate-oidc-issuer="https://token.actions.githubusercontent.com" \
  ghcr.io/your-username/your-repo-name:stable
```

Unsigned images fail the promotion gate, so `main → stable` reports
`release/blocked` until signing is restored.

### Where the signature is checked

**In CI, on the way to `:stable` — and not verified on the device.** The
promotion gate is the only enforcement point. An installed system pulls its
updates over an unverified transport (`image-info.json`'s `image-ref` is
`ostree-unverified-image:docker://…`), so `bootc upgrade` does not check the
cosign signature.

That is a deliberate statement of what the image can actually do, not an
oversight. Device-side verification runs through
`/etc/containers/policy.json`, which matches a keyless Fulcio certificate on
`subjectEmail` only — mandatory and exact. A GitHub Actions certificate
identifies its workflow in a URI SAN and carries no email, so no policy entry
can match it, and the inherited policy's `""` catch-all
(`insecureAcceptAnything`) would accept the image regardless. A signed-looking
`image-ref` here would verify nothing while implying it verified something.

Making updates verify on the device means signing with a key the policy can
name: publish with a cosign keypair, merge a `sigstoreSigned` scope for your
namespace into the inherited policy (with `jq`, during
[`build/10-overlay.sh`](build/10-overlay.sh) — never by shipping a whole
`policy.json` through `custom/files/`, which freezes every scope you inherited),
add a `registries.d` entry with `use-sigstore-attachments: true` for it, and
flip `IMAGE_REF` back to `ostree-image-signed:`. Validate that on a real
install before shipping it: a scope that does not match turns `bootc upgrade`
into a hard refusal. `tests/contract/image-signing_test.bats` holds the two
sides together, so changing one without the other fails the suite.

## Using your image

Switch to a built image:

```bash
sudo bootc switch --transport registry ghcr.io/your-username/your-repo-name:stable-testing
sudo systemctl reboot
```

Then, as your user:

```bash
ujust install-default-apps    # Homebrew: the default Brewfile
ujust install-dev-tools       # Homebrew: the development Brewfile
ujust configure-dev-groups    # add yourself to docker and libvirt
ujust install-config          # re-apply the image defaults, backing up yours
```

First boot unpacks Homebrew and installs the declared Flatpaks; both need a
network connection. Check them with `systemctl status brew-setup.service` and
`systemctl status flatpak-preinstall.service`.

## Local testing

```bash
just build            # build the container image
just build-qcow2      # build a QCOW2 disk image
just run-vm-qcow2     # boot it in a browser-based VM
just build-iso        # build an installer ISO
just test-unit        # run the test suite
```

## Troubleshooting

[The `troubleshooting` skill](.agents/skills/troubleshooting/SKILL.md) covers
build, CI, and runtime failures symptom-first. The two most common first-boot
surprises:

- **No Flatpaks.** `flatpak-preinstall.service` needs a network connection and
  reports success even when it cannot reach Flathub, so a first boot before
  Wi-Fi is configured installs nothing. Reboot once you are online.
- **No `brew`.** `brew-setup.service` unpacks Homebrew on first boot; check its
  status before reaching for a reinstall.

## Community

- [Universal Blue Discord](https://discord.gg/WEu6BdFEtp)
- [bootc discussions](https://github.com/bootc-dev/bootc/discussions)

## Learn more

- [Universal Blue](https://universal-blue.org/)
- [bootc](https://containers.github.io/bootc/)
- [Project Bluefin contributing guide](https://docs.projectbluefin.io/contributing/)

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
