"""Contracts for first-boot root password credential provisioning.

Root/core accounts are created by systemd-sysusers on first boot; root's
password is supplied as a systemd credential (TPM2-sealed when available)
rather than being pre-seeded (and locked) in /etc/shadow.
"""

from __future__ import annotations

from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
SYSUSERS_CONF = REPO_ROOT / "files" / "os" / "sysusers.d" / "10-root-creds.conf"
DDI_ELEMENT = REPO_ROOT / "elements" / "oci" / "microraptor-ddi.bst"
STACK_BST = REPO_ROOT / "elements" / "microraptor" / "os-stack.bst"
ISSUE_FILE = REPO_ROOT / "files" / "os" / "issue.d" / "40-kubestellar.issue"
UNIT = REPO_ROOT / "files" / "os" / "cred-provision" / "system" / "microraptor-cred-provision.service"
SCRIPT = REPO_ROOT / "files" / "os" / "cred-provision" / "microraptor-cred-provision"
IMPORT_DROPIN = (
    REPO_ROOT
    / "files"
    / "os"
    / "cred-provision"
    / "system"
    / "systemd-sysusers.service.d"
    / "50-import-root-credentials.conf"
)
OS_CRED_PROVISION = REPO_ROOT / "elements" / "microraptor" / "os-cred-provision.bst"


def test_sysusers_defines_root_and_core_without_passwords() -> None:
    content = SYSUSERS_CONF.read_text(encoding="utf-8")
    # `u` lines must carry no password field: root is provisioned via the
    # passwd.hashed-password.root credential, core stays locked.
    assert "u root 0 \"root\" /root /bin/sh" in content
    assert any(line.startswith("u core ") for line in content.splitlines())

def test_sysusers_does_not_hardcode_a_password_hash() -> None:
    content = SYSUSERS_CONF.read_text(encoding="utf-8")
    assert "root:!" not in content
    assert "$6$" not in content


def test_ddi_no_longer_seeds_locked_root_account() -> None:
    ddi = DDI_ELEMENT.read_text(encoding="utf-8")
    assert "root:!" not in ddi
    assert "Seed locked root account" not in ddi


def test_ddi_removes_scaffolds_and_enables_sysusers_and_provisioner() -> None:
    ddi = DDI_ELEMENT.read_text(encoding="utf-8")
    assert "rm -f /layer/etc/passwd /layer/etc/group /layer/etc/shadow" in ddi
    assert (
        "sysinit.target.wants/systemd-sysusers.service" in ddi
    )
    assert (
        "sysinit.target.wants/microraptor-cred-provision.service" in ddi
    )


def test_os_stack_wires_provisioning_and_tpm2_tss() -> None:
    stack = yaml.safe_load(STACK_BST.read_text(encoding="utf-8"))
    depends = stack.get("depends", [])
    assert "microraptor/os-cred-provision.bst" in depends
    assert "freedesktop-sdk.bst:components/tpm2-tss.bst" in depends


def test_provisioning_unit_is_an_early_sysinit_oneshot() -> None:
    unit = UNIT.read_text(encoding="utf-8")
    assert "DefaultDependencies=no" in unit
    assert "Before=systemd-sysusers.service" in unit
    assert "Type=oneshot" in unit
    assert "ConditionFirstBoot=yes" in unit


def test_provisioning_script_seals_to_tpm2_or_plaintext_fallback() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    assert "--with-key=tpm2" in script
    assert "passwd.hashed-password.root" in script
    assert "/etc/credstore.encrypted" in script
    assert "/etc/credstore" in script


def test_provisioning_default_password_matches_console_banner() -> None:
    script = SCRIPT.read_text(encoding="utf-8")
    banner = ISSUE_FILE.read_text(encoding="utf-8")
    assert "bluefin" in script
    assert "root / bluefin" in banner


def test_sysusers_imports_root_password_credentials() -> None:
    dropin = IMPORT_DROPIN.read_text(encoding="utf-8")
    assert "ImportCredential=passwd.hashed-password.root" in dropin
    assert "ImportCredential=passwd.plaintext-password.root" in dropin


def test_os_cred_provision_element_installs_unit_and_dropin() -> None:
    element = yaml.safe_load(OS_CRED_PROVISION.read_text(encoding="utf-8"))
    assert element.get("kind") == "import"
    assert element.get("config", {}).get("target") == "/usr/lib/systemd"
    assert any(
        source.get("path") == "files/os/cred-provision"
        for source in element.get("sources", [])
    )