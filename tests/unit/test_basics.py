#!/usr/bin/env python3
"""Unit tests for microraptor."""
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_project_conf_has_release_version():
    conf = (ROOT / "project.conf").read_text()
    assert "release-version:" in conf, "project.conf missing release-version"


def test_freedesktop_sdk_ref_matches():
    conf = (ROOT / "project.conf").read_text()
    junction = (ROOT / "elements" / "freedesktop-sdk.bst").read_text()
    import re
    conf_v = re.search(r"release-version:\s*[\"']?([0-9]+\.[0-9]+\.[0-9]+)", conf)
    junction_v = re.search(r"freedesktop-sdk-([0-9]+\.[0-9]+\.[0-9]+)", junction)
    assert conf_v and junction_v, "Could not parse versions"
    assert conf_v.group(1) == junction_v.group(1), "release-version drift"


def test_bootc_stack_has_network_manager():
    stack = (ROOT / "elements" / "microraptor" / "bootc-stack.bst").read_text()
    assert "network-manager.bst" in stack, "bootc-stack missing network-manager.bst"
    assert "os-network-manager.bst" in stack, "bootc-stack missing os-network-manager.bst"


def test_bootc_stack_includes_dbus_broker():
    stack = (ROOT / "elements" / "microraptor" / "bootc-stack.bst").read_text()
    assert "dbus.bst" in stack, "bootc-stack missing dbus.bst for dbus.socket"
    assert "dbus-broker.bst" in stack, "bootc-stack missing dbus-broker.bst"
    assert "gnome-build-meta.bst:gnomeos-deps/bootc.bst" in stack, "bootc-stack missing bootc.bst"


def test_installer_repart_has_labels():
    for f in ["bootc-target-10-esp.conf", "bootc-target-20-root.conf"]:
        content = (ROOT / "files" / "installer" / "repart.d" / f).read_text()
        assert "[Partition]" in content, f"{f} missing [Partition]"


def test_skills_index_exists():
    assert (ROOT / "docs" / "skills" / "index.md").exists()


def test_logind_ignores_lid_switch():
    bootc = (ROOT / "elements" / "oci" / "microraptor-bootc.bst").read_text()
    installer = (ROOT / "elements" / "oci" / "microraptor-installer-bootc.bst").read_text()
    assert "HandleLidSwitch=ignore" in bootc
    assert "HandleLidSwitchExternalPower=ignore" in bootc
    assert "HandleLidSwitch=ignore" in installer
    assert "HandleLidSwitchExternalPower=ignore" in installer


def test_bootc_image_has_containers_bootc_label():
    bootc = (ROOT / "elements" / "oci" / "microraptor-bootc.bst").read_text()
    assert "containers.bootc" in bootc, "bootc image missing containers.bootc label"


def main():
    tests = [
        test_project_conf_has_release_version,
        test_freedesktop_sdk_ref_matches,
        test_bootc_stack_has_network_manager,
        test_bootc_stack_includes_dbus_broker,
        test_installer_repart_has_labels,
        test_skills_index_exists,
        test_logind_ignores_lid_switch,
        test_bootc_image_has_containers_bootc_label,
    ]
    failed = 0
    for test in tests:
        try:
            test()
            print(f"PASS: {test.__name__}")
        except AssertionError as e:
            print(f"FAIL: {test.__name__}: {e}")
            failed += 1
        except Exception as e:
            print(f"ERROR: {test.__name__}: {e}")
            failed += 1
    if failed:
        sys.exit(1)
    print(f"All {len(tests)} tests passed.")


if __name__ == "__main__":
    main()