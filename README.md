# microraptor

**An FSDK-based, image-based Linux server OS for the KubeStellar factory.**

microraptor targets the same use-case space as Flatcar Container Linux, Fedora CoreOS, and Talos, but is built from scratch with [BuildStream 2](https://buildstream.build/) from [freedesktop-sdk](https://freedesktop-sdk.freedesktop.org/) components.

It is [DDI first](https://0pointer.net/blog/fitting-everything-together.html): the OS payload is a compressed XFS DDI filesystem image that is deployed by an offline, systemd-native installer.

## What it is

- **Image-based updates and atomic rollbacks** via A/B partition slots (`Microraptor-root-a`, `Microraptor-root-b`) and `systemd-sysupdate`.
- **DDI-first delivery** — the installer embeds the OS payload as a data partition; no network is required at install time.
- **Flatcar-style FSDK base** — built from freedesktop-sdk components, following the same immutable OS model as Flatcar Container Linux.
- **KubeStellar-native** — ships the KubeStellar control plane, console, and kiosk proxy as a `systemd-sysext` that activates on first boot.
- **Key-only operator access** — no root password. The `core` operator account is created on first boot by `systemd-sysusers`; SSH authorized keys are provisioned via `systemd-creds` and the console is available at `http://<local-ip>:8080`.
- **First-boot network setup** — `nmtui` launches automatically on the first boot so the operator can configure Wi-Fi or wired networking interactively.
- **systemd-native installer** — `systemd-sysinstall` provides the interactive terminal UI and `systemd-repart` handles GPT partitioning and block-copy DDI placement.
- **Read-only root** — the root filesystem is mounted `ro`; all mutable state lives in `/var`.

## Architecture

### Partitions

| Label | Type | Purpose |
|---|---|---|
| `Microraptor-ESP` | ESP | EFI system partition, holds UKIs and boot loader |
| `Microraptor-root-a` | root | Active OS slot (mounted `ro`) |
| `Microraptor-root-b` | root | Inactive OS slot for atomic updates |
| `var` | var | Persistent mutable state (`/var`) |

### Boot flow

1. `systemd-boot` discovers two UKIs on the ESP:
   - `microraptor-a.efi` — boots `Microraptor-root-a` (default)
   - `microraptor-b.efi` — boots `Microraptor-root-b` (fallback)
2. The active UKI mounts its root partition read-only.
3. `systemd-sysusers` creates the `core` operator account on first boot.
4. `systemd-tmpfiles-setup` applies `tmpfiles.extra` to seed `/var/home/core/.ssh`.
5. `bluefin-core-ssh-keys.service` consumes the `ssh.authorized_keys` systemd credential and writes it to `/var/home/core/.ssh/authorized_keys`.
6. `bluefin-core-access.service` verifies the authorized keys file exists before `sshd` starts.
7. `microraptor-first-boot-network.service` launches `nmtui` on the console (once) so the operator can configure networking.
8. `k0s-first-boot.service` activates the k0s sysext, which brings up KubeStellar, the console, and the kiosk proxy.

### A/B updates

`systemd-sysupdate` stages new OS images into the inactive root slot. After a successful update, the boot loader entry is swapped so the next reboot uses the new slot. If the new slot fails to boot, the operator can select the previous slot from the systemd-boot menu.

Updates are verified with GPG-signed `SHA256SUMS` manifests from GitHub Releases.

### Operator access

- Login as `core` via SSH with an authorized public key.
- Elevate with passwordless `sudo`.
- Root login and password authentication are disabled.
- The KubeStellar console is reachable at `http://<local-ip>:8080/`.

## Building

You need only [`just`](https://github.com/casey/just). BuildStream runs inside the FSDK `bst2` container, so BuildStream is not installed locally.

```bash
just validate              # resolve the element graph
just build-installer       # build the offline installer
just export-installer      # write artifacts to dist/
just show-me-the-future    # QEMU installer smoke test
```

See [`AGENTS.md`](AGENTS.md) for the full build matrix and agent skill routing.

## Project layout

| Path | Purpose |
|---|---|
| `elements/` | BuildStream elements (DDI, installer, OS stack, sysexts) |
| `files/os/` | OS payload: systemd units, sysusers, tmpfiles, SSH config, issue banner |
| `files/installer/` | Installer payload: repart configs, sysinstall script |
| `files/k0s/` | k0s sysext: manifests, kiosk assets, kubeflex helpers |
| `include/` | Version variables (`k0s.yml`, `arch.yml`) |
| `docs/skills/` | Task-specific guidance (installer, sysupdate, factory integration) |
| `tests/unit/` | pytest contracts for repart, login, sysupdate, kiosk |
| `Justfile` | Build and test commands |

## Contributing

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for the contributor checklist and [`docs/skills/index.md`](docs/skills/index.md) for task-specific guidance.

## Security

See [`SECURITY.md`](SECURITY.md) for the vulnerability disclosure policy, supported versions, and how to verify signed release artifacts.

## Release trust

- GitHub Actions builds all artifacts, signs a combined `SHA256SUMS` manifest, and publishes a GitHub Release.
- Updates are verified with GPG-signed `SHA256SUMS` manifests from GitHub Releases.
- See [`docs/skills/systemd-sysupdate-verification.md`](docs/skills/systemd-sysupdate-verification.md) for the trust model.

## License

Apache-2.0.
