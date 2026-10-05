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

**The Flatpak row is a preference, not a rule.** It is where a GUI app belongs
*if it is on Flathub* — a build-time RPM for the same app is a second, larger,
updater-less copy that Flakpak would have kept current. When an app is not on
Flathub and has no repository, the choice is a build-time RPM or nothing, and
"nothing" is a real answer worth saying out loud to the user rather than
inferring.

## Check upstream before choosing

Before adding anything, establish where it actually ships. It costs one API call
and it decides the destination:

```bash
# Flathub, by search rather than by guessed app ID
curl -fsS -X POST https://flathub.org/api/v2/search \
  -H 'content-type: application/json' \
  -d '{"query":"NAME","filters":[],"page":1,"per_page":5}'

# Homebrew
curl -fsS https://formulae.brew.sh/api/formula/NAME.json

# GitHub releases: assets, sizes, and whether anything is signed
curl -fsS https://api.github.com/repos/OWNER/REPO/releases/latest
```

Then read the project's own install docs for the release you pinned. They name
the runtime dependencies, the CPU or architecture floor, and often the split
between a monolithic package and per-variant binaries — the last of which is the
difference between a 20 MB layer and a 700 MB one.

Assume nothing about what is verified. Check whether the package is signed
before claiming it is: `rpm -Kv pkg.rpm` prints `Signature: (none)` for a
plenty of published RPMs, and a release can ship `SHA256SUMS.txt` that covers its
loose binaries but not the package it built from them.

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

### A package with no repository

Some projects publish a release artifact and nothing a distro could repackage —
no repo, no COPR, no Flathub. Voxtype is the one in this image. It still belongs
in the package phase, but it needs the integrity work dnf5's repository metadata
would otherwise do:

- Pin the version in the URL and the artifact's sha256 beside it, derived from
  one variable so they cannot disagree.
- **Verify before installing, not after.** dnf5 unpacks the payload as it goes.
- `--nogpgcheck` if the artifact is unsigned. That says there is nothing to
  check; it is not a substitute for the digest.
- Install the fetching tool (`curl`) explicitly. Relying on the package's own
  dependency on it is circular.
- `/tmp` is tmpfs for the build phases, so the download never reaches a layer.

An unsigned artifact is common enough that "pinned digest" is the floor, not the
ceiling. Prefer a signed one when upstream offers both.

**Size is a decision, not a detail.** A package that bundles every CPU and GPU
variant can be hundreds of megabytes, and that is sometimes correct — an image
that ships to unknown hardware cannot pick a variant at build time. Say the size
and the reason out loud before installing it, so the user can overrule.

**Do not enable the app's service.** An application whose first run needs a
per-machine download, a licence click, or a keyring is not ready at build time.
Install it, document the enable step, leave the unit alone.

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

`just test-unit` is the gate that catches a wiring mistake, and it is worth
running before claiming a change works. It needs no image build, so a suite that
only fails on a real `just build` is a suite that will not be run.

**A red suite on `main` is not your change.** Record the failing test names
before you start and compare after, so "pre-existing" is a claim you can back:

```bash
git stash && just test-unit 2>&1 | grep -E '^not ok' | sort > /tmp/base.txt
git stash pop && just test-unit 2>&1 | grep -E '^not ok' | sort > /tmp/new.txt
comm -13 /tmp/base.txt /tmp/new.txt   # regressions: failing now, passing before
```

**A unit test of a build script needs the script sandboxed.** The script runs as
root in the image and writes to real system paths — `/usr/lib/systemd`,
`/etc/yum.repos.d`, anywhere `sed -i` appears. A harness that stubs `dnf5` but
execs the real script then fails on a read-only root with a `sed` error instead
of an assertion, and every test in the file reports the same non-failure. Rewrite
every such path into a temp sandbox with `sed` in `setup()`, and guard the guard
with a test that greps the sandboxed copy for the un-rewritten path. The
guard is the only thing that notices when a new write is added.
