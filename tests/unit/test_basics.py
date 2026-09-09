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


def test_os_stack_has_network_manager():
    stack = (ROOT / "elements" / "microraptor" / "os-stack.bst").read_text()
    assert "network-manager.bst" in stack, "os-stack missing network-manager.bst"
    assert "os-network-manager.bst" in stack, "os-stack missing os-network-manager.bst"


def test_os_stack_includes_dbus_broker():
    stack = (ROOT / "elements" / "microraptor" / "os-stack.bst").read_text()
    assert "dbus.bst" in stack, "os-stack missing dbus.bst for dbus.socket"
    assert "dbus-broker.bst" in stack, "os-stack missing dbus-broker.bst"


def test_installer_repart_has_labels():
    for f in ["10-esp.conf", "20-root-a.conf", "30-var.conf"]:
        content = (ROOT / "files" / "installer" / "repart.d" / f).read_text()
        assert "[Partition]" in content, f"{f} missing [Partition]"


def test_skills_index_exists():
    assert (ROOT / "docs" / "skills" / "index.md").exists()


def test_quadlets_present():
    templates = ["pihole.container", "hermes-agent.container", "glance.container", "vaultwarden.container", "tailscale.container"]
    for q in templates:
        assert (ROOT / "files" / "os" / "containers" / "systemd" / "templates" / q).exists(), f"Missing quadlet template: {q}"


def test_os_stack_no_longer_installs_quadlets_base():
    stack = (ROOT / "elements" / "microraptor" / "os-stack.bst").read_text()
    assert "os-containers.bst" not in stack, "quadlets should be optional via sysext"
    assert "os-quadlets-sysupdate.bst" in stack, "os-stack missing os-quadlets-sysupdate.bst"
    assert "os-quadlets-first-boot.bst" in stack, "os-stack missing os-quadlets-first-boot.bst"


def test_quadlets_yml_has_versions():
    yml = (ROOT / "include" / "quadlets.yml").read_text()
    for service in ["pihole", "hermes", "glance", "vaultwarden", "tailscale"]:
        assert f"{service}-image:" in yml, f"quadlets.yml missing {service}-image"
        image_line = next((l for l in yml.splitlines() if l.strip().startswith(f"{service}-image:")), "")
        assert ":latest" not in image_line, f"quadlets.yml contains :latest tag for {service}"


def test_tailscale_quadlet_present():
    assert (ROOT / "files" / "os" / "containers" / "systemd" / "templates" / "tailscale.container").exists()


def main():
    tests = [
        test_project_conf_has_release_version,
        test_freedesktop_sdk_ref_matches,
        test_os_stack_has_network_manager,
        test_os_stack_includes_dbus_broker,
        test_installer_repart_has_labels,
        test_skills_index_exists,
        test_quadlets_present,
        test_os_stack_no_longer_installs_quadlets_base,
        test_quadlets_yml_has_versions,
        test_tailscale_quadlet_present,
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
