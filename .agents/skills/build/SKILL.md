---
name: build
description: >-
  The Containerfile, Justfile, build phases, image pinning, and the example
  scripts. Use when changing how the image is assembled or activating an
  example.
---

# Build

## The Containerfile

There are two: `Containerfile.workstation` and `Containerfile.homelab`. The
flavour is the third argument to `build`, the Containerfile is
`Containerfile.<flavor>`, and it is always passed with `-f`. `podman build .`
with no `-f` looks for a file literally called `Containerfile`, and there is no
longer one — so leaving `-f` off fails with "no Containerfile found" and names
neither file. `workstation` is the default so the two-argument CI call still
works.

Structure, in order:

1. **Identity** — `ARG IMAGE_NAME`, `IMAGE_VENDOR`, `UBLUE_IMAGE_TAG`, and the
   `# Name:` comment. The name actually published is the repository name; these
   are the local fallback and the image metadata.
2. **Context stage** — `COPY build /build`, `COPY custom /custom`, then the two
   OCI images into `/oci/common` and `/oci/brew`.
3. **Base** — the `FROM` line. The only place the base is chosen; the Fedora
   major, the image name, and the digest all follow from it.
4. **Phases** — one `RUN` block per script, in the order they are named.
   [build/README.md](../../../build/README.md) lists them.
5. **Metadata** — the `LABEL` block, fed by ARGs declared late so a new version
   or commit only invalidates the label layer.

Order matters for cache: volatile values go after the expensive layers.

## The Justfile

```bash
just build            # build the image
just build-qcow2      # build a QCOW2 disk image
just build-iso        # build an installer ISO
just run-vm-qcow2     # boot the image in a VM
just test-unit        # run the suite
just lint             # shellcheck every tracked script
just check            # verify Justfile syntax
```

`just --list` has the rest. `IMAGE_NAME` defaults to the value in the Justfile
and is overridable by the `IMAGE_NAME` environment variable; CI sets that from
the repository name.

## Pinning

Every OCI reference is pinned by digest and updated by Renovate: the base image,
`projectbluefin/common`, `ublue-os/brew`, `bootc-image-builder`, and the GitHub
Actions. Do not hand-edit a digest; let Renovate propose it.

Renovate cannot help with a binary that has no repository, and one artifact here
is worse than the others for that reason: **`kc-agent` is a nightly.**
`kubestellar/console` publishes only `vX.Y.Z-nightly.DATE` tags, all marked
prerelease, so there is no stable to move to and no upstream signal about when a
bump matters. The tag is dated and therefore does not rot on its own, but the
image carries a prerelease nobody will patch. `build/35-kc-agent.sh` documents
this at the pin. If a stable release ever appears, move it to Renovate.

### Glob patterns silently match nothing

Three of these were broken by the two-Containerfile rename and all three failed
quietly rather than loudly:

- `hashFiles('**/Containerfile')` in a workflow's dnf-cache `cache-bust` stops
  matching. Builds stay **correct** and get slower; nothing logs a warning.
- `dockerfile: "Containerfile"` for hadolint stops matching. PR validation lints
  nothing and is still green.
- An `org.opencontainers.image.source` label naming `.../blob/main/Containerfile`
  is a 404 on every image ever built from that commit.

The pattern to use is `Containerfile.*`, and the tests in
`tests/template/flavours_test.bats` assert each of these so the next rename cannot
reintroduce them.

**Resolve a digest for the platform you build, not from the manifest list.**
`skopeo inspect --raw` returns the index, and the per-platform entries inside it
are not always digests the registry will serve for a direct `image@digest` pull —
taking one from there produces a reference that is 64 hex characters, names the
right image, and fails to pull with `manifest unknown`. Use the platform-resolved
form, which is the digest `FROM` should carry:

```sh
skopeo inspect docker://quay.io/fedora/fedora:44 --format '{{.Digest}}'
```

Confirm it before wiring it in — a bad digest fails at the `FROM` line, after
the whole build has been scheduled:

```sh
skopeo inspect --raw "docker://<image>@<digest>" >/dev/null && echo pullable
```

Renovate updates whatever digest is in the `FROM` line, so a correct one is
maintained; a wrong one is maintained just as faithfully.

The base image's `FROM` line is the only place the base is chosen, so the Fedora
major cannot desync the way a hand-maintained `FEDORA_MAJOR_VERSION` ARG could.
Two readers derive it from that base: `just build` parses the tag for the version
string, and `00-image-info.sh` reads the base's `os-release` for the image
metadata.

`BASE_IMAGE_NAME` has no default in the Containerfile on purpose: a stale default
like `silverblue` would silently mislabel a CentOS or Hummingbird fork. `just
build` fills it from the `FROM` line and `00-image-info.sh` hard-fails on an empty
value, so build through `just`; a bare `podman build .` is unsupported.

## Examples

`build/*.sh.example` are inactive until you activate them: rename the file off
`.example` and add a `RUN` block after the package phase.
[build/README.md](../../../build/README.md) has the block to copy.
