---
name: customize
description: >-
  Decide where a package, app, or command belongs — dnf5 at build time,
  Homebrew, Flatpak, or ujust — and how each is validated. Use when adding
  or removing something from the image.
---

# Customize

## Where does it go?

| The thing is… | Put it in | Installed |
|---|---|---|
| A system package the image needs to boot or run | a `build/NN-*.sh` phase | at build time |
| A CLI tool a user chooses to have | `custom/brew/*.Brewfile` | on demand, by the user |
| A GUI application | `custom/flatpaks/*.preinstall` | on first boot |
| A command that configures the system | `custom/ujust/*.just` | available from first login |
| A system file: unit, preset, tmpfiles.d | `custom/files/` | at build time |
| Per-user config for new accounts | `custom/config/` | at build time, into `/etc/skel` |

The dividing line is who decides and when: build time for what the image must
have, runtime for what the user chooses.

**Check the default Brewfile before adding a CLI tool.** If it is already
there, the build is the second copy at a second version.

## Which build phase

`build/` is numbered, and each phase owns one concern. [build/README.md](../../../build/README.md)
has the current map. Add to an existing phase when the justification is the same
kind of thing; add a new one when it is not.

`20-packages-and-services.sh` is "what the image **is**" — the desktop, the
compositor, the display manager, the update daemon. `25-hardware-and-session.sh`
is "what the image needs in order to **function**", and the reasoning there is
per-package: why the WiFi firmware is 147 MB, why `NetworkManager-wifi` has no
unit to enable, why the bash completion hook is in `/etc/bashrc`. `30-`/`40-` are
the kernel and GPU driver, which are reversible as a pair.

The test for a new phase is whether a reader asking "why is this here?" gets a
different answer than they would for the existing ones. If not, it belongs in
one of them.

## By destination

### Build-time packages

`build/20-packages-and-services.sh`. Use `dnf5`, always with `-y`, and disable
any repository you enable. [build/README.md](../../../build/README.md) has the
phase map.

Prefer a package the base already ships. When a COPR is unavoidable,
`copr_install_isolated` enables and disables it for you.

### Homebrew

Brewfiles in `custom/brew/`, plus a `ujust` recipe so users install it by name.
[custom/brew/README.md](../../../custom/brew/README.md) has the format.

### Flatpak

Preinstall declarations in `custom/flatpaks/`. The app must exist on Flathub;
`just validate-flatpaks` checks.
[custom/flatpaks/README.md](../../../custom/flatpaks/README.md) has the format and
the first-boot behaviour.

### ujust

Recipes in `custom/ujust/`. No `dnf5` or `rpm` — the image is immutable.
[custom/ujust/README.md](../../../custom/ujust/README.md) has the recipe shape.

### System files and user config

`custom/files/` mirrors `/`; `custom/config/` seeds `/etc/skel/.config/`. Each
directory's README has the semantics.

## Removing something

The reverse of adding: delete the line or the file, then check nothing still
references it. A package removed from the package phase may still arrive as a
dependency or from an overlay; `bootc container lint` and the image build catch
the obvious cases.

## Validate

```bash
just validate-brewfiles
just validate-flatpaks
just check
just build
```

CI runs `validate-brewfiles`, `validate-flatpaks`, and `validate-justfiles` on
every pull request.
