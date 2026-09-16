# microraptor — Agent Entry Point

microraptor is an FSDK-based, image-based Linux server OS. It produces:
- a bootc OCI image (`oci/microraptor-bootc.bst`)
- a shell-based installer raw disk (`oci/microraptor-installer-bootc.bst`)

## What agents should know first

1. Read this file.
2. Load [`docs/skills/index.md`](docs/skills/index.md) to route to the skill for your task.
3. Never guess label names, workflow secrets, or infrastructure hostnames — check the relevant skill.

## Hard rules

1. Compose from FSDK `components/*`. Never use `platform.bst`.
2. Keep the CPU baseline broad: no `x86_64_v3`.
3. SSH is included for standard server administration; root login is permitted with key-based auth only (see [`files/os/ssh/sshd_config.d/microraptor.conf`](files/os/ssh/sshd_config.d/microraptor.conf)).
4. Boot entries use GPT `PARTUUID`; never hardcode device paths.
5. One canonical source per fact; do not duplicate content across docs.

## Build / test commands

All `just` targets run BuildStream inside the FSDK `bst2` container via `just bst`; BuildStream is not installed locally.

| Command | Purpose |
|---|---|
| `just validate` | Merge-contract graph check — run this on every change. |
| `just build-bootc` | Local bootc OCI image build. |
| `just export-bootc` | Export bootc OCI image to podman. |
| `just build-installer-bootc` | Local bootc installer build. |
| `just export-installer-bootc` | Export bootc installer to `dist/`. |
| `just generate-bootable-image` | Generate bootable raw disk via `bootc install to-disk --via-loopback`. |
| `just show-me-the-future` | Local QEMU installer smoke test. |

## Skill routing

| Task | Skill |
|---|---|
| Build or debug the bootc installer | [`docs/skills/ddi-installer.md`](docs/skills/ddi-installer.md) |
| Build bootc OCI image | [`docs/skills/ddi-installer-build.md`](docs/skills/ddi-installer-build.md) |
| Factory role, lab integration | [`docs/skills/factory-integration.md`](docs/skills/factory-integration.md) |
| Work with `systemd-sysext` / `systemd-confext` | [`docs/skills/systemd-sysext-extensions.md`](docs/skills/systemd-sysext-extensions.md) |
| Update the FSDK pin / versioning | [`docs/skills/bump-fsdk-version.md`](docs/skills/bump-fsdk-version.md) |
| CI workflows, action SHA pinning | [`docs/skills/ci-tooling.md`](docs/skills/ci-tooling.md) |
| Release signing / bootc trust | [`docs/skills/bootc-upgrades.md`](docs/skills/bootc-upgrades.md) |
| Credential sealing with TPM2 | [`docs/skills/tpm2-credential-sealing.md`](docs/skills/tpm2-credential-sealing.md) |
| System containers (`machinectl`) | [`docs/skills/system-containers.md`](docs/skills/system-containers.md) |
| Cut bloat / avoid over-engineering | [`docs/skills/avoid-over-engineering.md`](docs/skills/avoid-over-engineering.md) |
| Add or refactor skills | [`docs/skills/skill-improvement.md`](docs/skills/skill-improvement.md) |

## Documentation conventions

- Update only the skill that matches your change.
- Keep `AGENTS.md` small; do not list deep context here.
- Remove `TODO/FIXME` and work-in-progress markers before merging; move unfinished work to issues.
- Use Conventional Commits. For doc-only changes: `docs:`.

## Boundaries

- Do not hardcode block device paths in boot configuration.
- Do not put Kubernetes or debug tooling in the base bootc image if it can live in a sysext or system container.
- Do not duplicate a fact already in a skill.

## Verification

- [ ] `just validate` passes.
- [ ] Any changed skill is listed in [`docs/skills/index.md`](docs/skills/index.md).
- [ ] No new internal-only hostnames or proprietary names appear in `AGENTS.md` or skills.