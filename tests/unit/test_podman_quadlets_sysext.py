"""Contracts for the podman-quadlets sysext BuildStream element."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_quadlets_version_ssot() -> None:
    yml = ROOT / "include" / "quadlets.yml"
    assert yml.is_file(), "include/quadlets.yml missing"
    import yaml

    data = yaml.safe_load(yml.read_text())
    vars_ = data.get("variables", {})
    assert "quadlets-version" in vars_


def test_podman_quadlets_sysext_element_exists() -> None:
    el = ROOT / "elements" / "oci" / "podman-quadlets-sysext.bst"
    assert el.is_file(), "elements/oci/podman-quadlets-sysext.bst missing"
    content = el.read_text(encoding="utf-8")
    assert "kind: manual" in content
    assert "include/quadlets.yml" in content
    assert "erofs-utils" in content
    assert "zstd" in content
    assert "files/quadlets/sysext" in content
    assert "extension-release.quadlets" in content
    assert "quadlets-manifests.conf" in content
    assert "podman-quadlets-%{quadlets-version}.raw" in content
    assert "usr/share/quadlets/examples" in content


def test_podman_quadlets_sysext_produces_compressed_ero() -> None:
    el = ROOT / "elements" / "oci" / "podman-quadlets-sysext.bst"
    content = el.read_text(encoding="utf-8")
    assert "mkfs.erofs" in content
    assert "zstd -T0 -19" in content
    assert "sha256sum" in content


def test_extension_release_metadata() -> None:
    rel = ROOT / "files" / "quadlets" / "sysext" / "extension-release.quadlets"
    assert rel.is_file(), "extension-release.quadlets missing"
    text = rel.read_text(encoding="utf-8")
    assert "NAME=quadlets" in text
    assert "ID=_any" in text
    assert "ID_LIKE=quadlets" in text
    assert "VERSION=%{quadlets-version}" in text


def test_sysext_contains_all_quadlet_files_and_tmpfiles() -> None:
    src = ROOT / "files" / "quadlets" / "sysext"
    assert (src / "quadlets-manifests.conf").is_file()
    for name in (
        "pihole.container",
        "vaultwarden.container",
        "glance.container",
        "hermes-agent.container",
        "tailscale.container",
    ):
        assert (src / name).is_file(), f"{name} missing from sysext pool"


def test_sysupdate_transfer_is_packaged_as_a_component() -> None:
    el = (ROOT / "elements" / "microraptor" / "os-quadlets-sysupdate.bst").read_text(
        encoding="utf-8"
    )
    assert "path: files/os/sysupdate.quadlets.d" in el
    assert "target: /usr/lib/sysupdate.quadlets.d" in el
    assert (
        "microraptor/os-quadlets-sysupdate.bst"
        in (ROOT / "elements" / "microraptor" / "os-stack.bst").read_text(encoding="utf-8")
    )


def test_first_boot_units_and_preset_are_packaged() -> None:
    stack_text = (ROOT / "elements" / "microraptor" / "os-stack.bst").read_text(
        encoding="utf-8"
    )
    assert "microraptor/os-quadlets-first-boot.bst" in stack_text

    preset = (
        ROOT
        / "files"
        / "os"
        / "systemd"
        / "system-preset"
        / "zz-enable-quadlets-first-boot.preset"
    )
    assert preset.is_file()
    assert preset.read_text(encoding="utf-8") == "enable quadlets-first-boot.service\n"

    fetch_svc = (
        ROOT
        / "files"
        / "os"
        / "systemd"
        / "system"
        / "quadlets-first-boot-fetch.service"
    )
    assert fetch_svc.is_file()
    assert "ConditionPathExists=!/var/lib/podman-quadlets/quadlets.raw" in fetch_svc.read_text(
        encoding="utf-8"
    )
    assert (
        "systemd-sysupdate --component=podman-quadlets update"
        in fetch_svc.read_text(encoding="utf-8")
    )

    svc = (
        ROOT
        / "files"
        / "os"
        / "systemd"
        / "system"
        / "quadlets-first-boot.service"
    )
    assert svc.is_file()
    svc_text = svc.read_text(encoding="utf-8")
    assert "systemd-sysext merge" in svc_text
    assert "/usr/share/quadlets/examples" in svc_text
    assert "/var/lib/containers/systemd" in svc_text
    assert "systemctl daemon-reload" in svc_text
    assert "pihole.service" in svc_text
    assert "vaultwarden.service" in svc_text
    assert "glance.service" in svc_text
    assert "hermes-agent.service" in svc_text
    assert "tailscale.service" in svc_text


def test_quadlets_first_boot_retry_semantics() -> None:
    fetch_svc = (
        ROOT
        / "files"
        / "os"
        / "systemd"
        / "system"
        / "quadlets-first-boot-fetch.service"
    )
    svc = (
        ROOT
        / "files"
        / "os"
        / "systemd"
        / "system"
        / "quadlets-first-boot.service"
    )

    fetch_text = fetch_svc.read_text(encoding="utf-8")
    svc_text = svc.read_text(encoding="utf-8")

    assert "Type=oneshot" in fetch_text
    assert "Restart=on-failure" in fetch_text
    assert "Before=quadlets-first-boot.service" in fetch_text
    assert "Wants=quadlets-first-boot-fetch.service" in svc_text
    assert "Requires=quadlets-first-boot-fetch.service" not in svc_text
    assert "After=quadlets-first-boot-fetch.service" in svc_text


def test_base_os_no_longer_installs_quadlets() -> None:
    stack_text = (ROOT / "elements" / "microraptor" / "os-stack.bst").read_text(
        encoding="utf-8"
    )
    assert "os-containers.bst" not in stack_text
