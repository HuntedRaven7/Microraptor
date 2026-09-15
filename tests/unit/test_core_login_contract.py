from pathlib import Path

import yaml

ROOT = Path(__file__).resolve().parents[2]
SYSUSERS = ROOT / "files/os/sysusers.d/10-root-creds.conf"
CORE_SYSUSERS = ROOT / "files/os/sysusers.d/10-core-user.conf"
TMPFILES = ROOT / "files/os/tmpfiles.d/10-core-home.conf"
SUDOERS = ROOT / "files/os/sudoers.d/10-wheel-nopasswd"
STACK = ROOT / "elements/microraptor/os-stack.bst"


def test_core_operator_is_stable_key_only_and_persistent() -> None:
    assert SYSUSERS.read_text(encoding="utf-8") == (
        'u root 0 "root" /root /bin/bash\n'
    )
    assert CORE_SYSUSERS.read_text(encoding="utf-8") == (
        'u core 1000 "core" /var/home/core /bin/bash\n'
        "m core wheel\n"
    )
    assert TMPFILES.read_text(encoding="utf-8") == (
        "d /var/home 0755 root root -\n"
        "d /var/home/core 0700 core core -\n"
        "d /var/home/core/.ssh 0700 core core -\n"
    )
    assert SUDOERS.read_text(encoding="utf-8") == "%wheel ALL=(ALL:ALL) NOPASSWD: ALL\n"


def test_core_login_elements_are_composed() -> None:
    depends = yaml.safe_load(STACK.read_text(encoding="utf-8"))["depends"]
    assert "freedesktop-sdk.bst:components/sudo.bst" in depends
    assert "microraptor/os-tmpfiles.bst" in depends
    assert "microraptor/os-sudo.bst" in depends


SSH_CONFIG = ROOT / "files/os/ssh/sshd_config.d/microraptor.conf"
CORE_ACCESS_SERVICE = ROOT / "files/os/systemd/system/bluefin-core-access.service"
SSHD_DROP_IN = ROOT / "files/os/systemd/system/sshd.service.d/10-bluefin-access.conf"


def test_ssh_is_key_only_and_never_accepts_root() -> None:
    assert SSH_CONFIG.read_text(encoding="utf-8") == (
        "PermitRootLogin no\n"
        "PubkeyAuthentication yes\n"
        "PasswordAuthentication no\n"
        "KbdInteractiveAuthentication no\n"
        "AuthorizedKeysFile /var/home/core/.ssh/authorized_keys\n"
    )


def test_sshd_requires_persistent_core_authorization() -> None:
    access = CORE_ACCESS_SERVICE.read_text(encoding="utf-8")
    drop_in = SSHD_DROP_IN.read_text(encoding="utf-8")

    assert "Requires=bluefin-core-ssh-keys.service var.mount" in access
    assert "After=bluefin-core-ssh-keys.service var.mount systemd-tmpfiles-setup.service" in access
    assert "Before=sshd.service" in access
    assert "ExecStart=/usr/bin/test -s /var/home/core/.ssh/authorized_keys" in access
    assert "Requires=bluefin-ssh-host-keys.service bluefin-core-access.service" in drop_in
    assert "ExecStartPre=" in drop_in
    assert "ExecStartPre=/usr/bin/test -s /var/lib/ssh/ssh_host_ed25519_key" in drop_in


ELEMENTS = ROOT / "elements"
FILES_OS = ROOT / "files/os"
PRESET_DIR = FILES_OS / "systemd/system-preset"


def _os_stack_import_sources() -> dict[str, dict[str, str | None]]:
    """Map every local source path packaged by the OS stack to its import element."""
    depends = yaml.safe_load(STACK.read_text(encoding="utf-8"))["depends"]
    packaged: dict[str, dict[str, str | None]] = {}
    for dep in depends:
        if not isinstance(dep, str) or not dep.startswith("microraptor/"):
            continue
        data = yaml.safe_load((ELEMENTS / dep).read_text(encoding="utf-8"))
        if not isinstance(data, dict) or data.get("kind") != "import":
            continue
        target = (data.get("config") or {}).get("target")
        for source in data.get("sources") or []:
            if isinstance(source, dict) and source.get("kind") == "local":
                packaged[source["path"]] = {"element": dep, "target": target}
    return packaged


def test_systemd_presets_are_packaged_by_the_os_stack() -> None:
    packaged = _os_stack_import_sources()
    entry = packaged.get("files/os/systemd/system-preset")
    assert entry is not None, (
        "files/os/systemd/system-preset is not imported by any element in os-stack.bst"
    )
    assert entry["target"] == "/usr/lib/systemd/system-preset"
    assert {path.name for path in PRESET_DIR.iterdir()} == {
        "zz-enable-sshd.preset",
        "zz-enable-k0s-first-boot.preset",
        "zz-enable-var-mount.preset",
    }


def test_no_os_payload_file_is_orphaned_from_the_os_stack() -> None:
    packaged = set(_os_stack_import_sources())
    orphans = []
    for path in sorted(FILES_OS.rglob("*")):
        if not path.is_file():
            continue
        rel = path.relative_to(ROOT)
        # Installer-only payloads (quadlets) are consumed by the installer
        # stack, not the OS stack, so they are not orphans.
        if "quadlets" in str(rel):
            continue
        covered = str(rel) in packaged or any(str(p) in packaged for p in rel.parents)
        if not covered:
            orphans.append(str(rel))
    assert orphans == [], f"OS payload files are not imported by any os-stack element: {orphans}"


DDI = ROOT / "elements/oci/microraptor-ddi.bst"
ISSUE = ROOT / "files/os/issue.d/40-kubestellar.issue"
SSHD_PRESET = ROOT / "files/os/systemd/system-preset/zz-enable-sshd.preset"


def test_ddi_restores_setuid_root_on_sudo() -> None:
    ddi = DDI.read_text(encoding="utf-8")
    assert "chmod 4755 /layer/usr/bin/sudo" in ddi, (
        "BuildStream strips setuid bits; the DDI must restore mode 4755 on /usr/bin/sudo "
        "so the key-only core operator can elevate through wheel"
    )


def test_ddi_contains_no_root_credential_or_shared_host_key() -> None:
    ddi = DDI.read_text(encoding="utf-8")
    assert "u root 0 \"root\" /root /bin/bash" in SYSUSERS.read_text(encoding="utf-8").splitlines()
    assert "rm -f /layer/etc/passwd /layer/etc/group /layer/etc/shadow" in ddi
    assert "bluefin123" not in ddi
    assert "$6$" not in ddi
    assert "root:!:" not in ddi
    assert "Default login: root / bluefin" not in ISSUE.read_text(encoding="utf-8")
    assert "/layer/etc/securetty" not in ddi
    assert "ssh-keygen -q -N" not in ddi
    assert "ln -sfn /var/home /layer/home" in ddi
    assert "bluefin-core-access.service" in ddi
    assert SSHD_PRESET.exists()


FIRST_BOOT_SERVICE = ROOT / "files/os/systemd/system/microraptor-first-boot-network.service"


def test_first_boot_network_service_is_idempotent_and_gated() -> None:
    service = FIRST_BOOT_SERVICE.read_text(encoding="utf-8")
    assert "ConditionPathExists=!/var/lib/first-boot-done" in service
    assert "After=systemd-sysusers.service systemd-tmpfiles-setup.service NetworkManager.service" in service
    assert "Before=sshd.service" in service
    assert "Conflicts=getty@tty1.service" not in service
    assert "ExecStart=/bin/sh -c '/usr/bin/nmtui || true'" in service
    assert "ExecStartPost=/usr/bin/touch /var/lib/first-boot-done" in service
    assert "TTYPath=/dev/console" in service
    assert "Environment=TERM=linux" in service
    assert "WantedBy=multi-user.target" in service


def test_ddi_enables_network_manager_and_first_boot_network() -> None:
    ddi = DDI.read_text(encoding="utf-8")
    assert "NetworkManager.service" in ddi
    assert "microraptor-first-boot-network.service" in ddi
    assert "rm -f /layer/etc/systemd/system/multi-user.target.wants/systemd-networkd.service" in ddi
    assert "rm -f /layer/etc/systemd/system/multi-user.target.wants/systemd-resolved.service" in ddi
    assert "ln -sf /usr/lib/systemd/system/sshd.service" in ddi
    assert FIRST_BOOT_SERVICE.exists()


INSTALLER = ROOT / "elements/oci/microraptor-installer.bst"
REPART_ROOT_A = ROOT / "files/installer/repart.d/20-root-a.conf"
REPART_ROOT_B = ROOT / "files/installer/repart.d/40-root-b.conf"


def test_installer_builds_ab_ukis_and_boot_entries() -> None:
    installer = INSTALLER.read_text(encoding="utf-8")
    assert "--cmdline=\"ro root=PARTLABEL=Microraptor-root-a" in installer
    assert "--cmdline=\"ro root=PARTLABEL=Microraptor-root-b" in installer
    assert "microraptor-a.efi" in installer
    assert "microraptor-b.efi" in installer
    assert "microraptor-a.conf" in installer
    assert "microraptor-b.conf" in installer


def test_repart_has_root_b_partition() -> None:
    assert REPART_ROOT_A.exists()
    assert REPART_ROOT_B.exists()
    assert "Label=Microraptor-root-a" in REPART_ROOT_A.read_text(encoding="utf-8")
    assert "Label=Microraptor-root-b" in REPART_ROOT_B.read_text(encoding="utf-8")


SSH_KEYS_SERVICE = ROOT / "files/os/systemd/system/bluefin-core-ssh-keys.service"


def test_ssh_keys_are_provisioned_via_systemd_creds() -> None:
    service = SSH_KEYS_SERVICE.read_text(encoding="utf-8")
    assert "ConditionPathExists=!/var/home/core/.ssh/authorized_keys" in service
    assert "systemd-creds cat ssh.authorized_keys" in service
    assert "Description=Provision core SSH authorized_keys from systemd-creds" in service
    assert "Before=bluefin-core-access.service sshd.service" in service