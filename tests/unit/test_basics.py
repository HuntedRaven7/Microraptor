#!/usr/bin/env python3
"""Unit tests for fsdk-it."""
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
    stack = (ROOT / "elements" / "fsdk-it" / "os-stack.bst").read_text()
    assert "network-manager.bst" in stack, "os-stack missing network-manager.bst"
    assert "os-network-manager.bst" in stack, "os-stack missing os-network-manager.bst"


def test_installer_repart_has_labels():
    for f in ["10-esp.conf", "20-root-a.conf", "30-var.conf"]:
        content = (ROOT / "files" / "installer" / "repart.d" / f).read_text()
        assert "[Partition]" in content, f"{f} missing [Partition]"


def test_skills_index_exists():
    assert (ROOT / "docs" / "skills" / "index.md").exists()


def test_quadlets_present():
    templates = ["pihole.container", "hermes-agent.container", "glance.container", "vaultwarden.container"]
    for q in templates:
        assert (ROOT / "files" / "os" / "containers" / "systemd" / "templates" / q).exists(), f"Missing quadlet template: {q}"


def test_os_stack_includes_containers():
    stack = (ROOT / "elements" / "fsdk-it" / "os-stack.bst").read_text()
    assert "os-containers.bst" in stack, "os-stack missing os-containers.bst"


def test_quadlets_yml_has_versions():
    yml = (ROOT / "include" / "quadlets.yml").read_text()
    for service in ["pihole", "hermes", "glance", "vaultwarden"]:
        assert f"{service}-image:" in yml, f"quadlets.yml missing {service}-image"
        assert ":latest" not in yml, f"quadlets.yml contains :latest for {service}"


def test_os_stack_includes_tailscale():
    stack = (ROOT / "elements" / "fsdk-it" / "os-stack.bst").read_text()
    assert "tailscale.bst" in stack, "os-stack missing tailscale.bst"


def test_tailscale_element_exists():
    assert (ROOT / "elements" / "fsdk-it" / "tailscale.bst").exists()


def main():
    tests = [
        test_project_conf_has_release_version,
        test_freedesktop_sdk_ref_matches,
        test_os_stack_has_network_manager,
        test_installer_repart_has_labels,
        test_skills_index_exists,
        test_quadlets_present,
        test_os_stack_includes_containers,
        test_quadlets_yml_has_versions,
        test_os_stack_includes_tailscale,
        test_tailscale_element_exists,
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
