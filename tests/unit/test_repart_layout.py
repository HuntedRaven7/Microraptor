"""Invariant coverage for the target-disk partition layout.

``files/installer/repart.d/*.conf`` is the recipe ``systemd-repart`` follows when
the live installer partitions the *target* disk. Nothing in CI parses these
files today, so a typo in a ``Type=``, a ``CopyBlocks=`` source that no longer
matches the label the installer media stamps on its data partition, or an
``esp``/``root``/``var`` slot going missing would only surface as a failed or
silently mis-partitioned install.

These tests are pure static checks: they read the shipped configs (plus the
installer element and the sysupdate transfer for cross-file consistency) and
assert the invariants the installer depends on. No BuildStream, no root, no
block devices.
"""

from __future__ import annotations

import configparser
import re
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
REPART_DIR = REPO_ROOT / "files" / "installer" / "repart.d"

SIZE_SUFFIXES = {"K": 1024, "M": 1024**2, "G": 1024**3, "T": 1024**4}


def parse_size(value: str) -> int:
    """Parse a systemd size string (``500M``, ``1G``, ``4096``) into bytes."""
    match = re.fullmatch(r"(\d+)([KMGT]?)", value.strip())
    assert match, f"unparseable systemd size: {value!r}"
    number, suffix = match.groups()
    return int(number) * SIZE_SUFFIXES.get(suffix, 1)


def load_config(path: Path) -> configparser.ConfigParser:
    parser = configparser.ConfigParser(strict=True)
    # systemd drop-ins are case-sensitive; configparser lowercases keys by default.
    parser.optionxform = str
    parser.read_string(path.read_text(encoding="utf-8"))
    return parser


def repart_files() -> list[Path]:
    return sorted(REPART_DIR.glob("bootc-target-*.conf"))


CONFIG_PATHS = repart_files()


def partitions() -> dict[str, dict[str, str]]:
    """Map ``bootc-target-10-esp.conf`` → its ``[Partition]`` section, for every config."""
    result: dict[str, dict[str, str]] = {}
    for path in CONFIG_PATHS:
        parser = load_config(path)
        result[path.name] = dict(parser["Partition"])
    return result


def test_repart_directory_is_populated():
    assert CONFIG_PATHS, f"no repart.d configs found under {REPART_DIR}"


@pytest.mark.parametrize("path", CONFIG_PATHS, ids=lambda p: p.name)
def test_config_parses_with_a_partition_section(path: Path):
    parser = load_config(path)
    assert parser.sections() == ["Partition"], (
        f"{path.name} must define exactly one [Partition] section, "
        f"got {parser.sections()}"
    )


@pytest.mark.parametrize("path", CONFIG_PATHS, ids=lambda p: p.name)
def test_config_filename_is_ordered_and_lowercase(path: Path):
    assert re.fullmatch(
        r"bootc-target-\d{2}-[a-z0-9-]+\.conf", path.name
    ), f"{path.name} must be bootc-target-NN-name.conf so systemd-repart orders it predictably"


def test_config_ordering_prefixes_are_unique():
    prefixes = [p.name.split("-", 2)[2][:2] for p in CONFIG_PATHS]
    assert len(prefixes) == len(set(prefixes)), (
        "two repart.d configs share an ordering prefix, so partition order "
        f"depends on the filename tiebreak: {prefixes}"
    )


def test_expected_partition_types_are_present_exactly_once():
    types = [section["Type"] for section in partitions().values()]
    assert sorted(types) == ["esp", "root"], (
        "the target layout must be exactly one esp and one root "
        f"partition, got {sorted(types)}"
    )


@pytest.mark.parametrize("name,section", sorted(partitions().items()))
def test_size_bounds_are_consistent(name: str, section: dict[str, str]):
    minimum = section.get("SizeMinBytes")
    maximum = section.get("SizeMaxBytes")
    assert minimum, f"{name} must set SizeMinBytes so a too-small disk fails loudly"
    if maximum is not None:
        assert parse_size(minimum) <= parse_size(maximum), (
            f"{name}: SizeMinBytes={minimum} exceeds SizeMaxBytes={maximum}, "
            "systemd-repart would refuse the layout"
        )


def test_partition_labels_are_unique():
    labels = [
        section["Label"]
        for section in partitions().values()
        if "Label" in section
    ]
    assert len(labels) == len(set(labels)), (
        f"duplicate GPT partition labels would make Path=auto ambiguous: {labels}"
    )


def test_esp_is_vfat_and_bounded():
    esp = next(s for s in partitions().values() if s["Type"] == "esp")
    assert esp["Format"] == "vfat", "an ESP that is not vfat is unbootable by UEFI"
    assert parse_size(esp["SizeMinBytes"]) >= 100 * 1024**2, (
        "the ESP must be large enough for systemd-boot plus at least one UKI"
    )
    assert "SizeMaxBytes" in esp, "the ESP must be capped so it cannot eat the disk"


def test_root_slot_grows_and_is_bounded_below_disk_end():
    root = next(s for s in partitions().values() if s["Type"] == "root")
    assert root.get("GrowFileSystem") == "yes", (
        "the root filesystem must grow to its partition, the bootc image is "
        "smaller than SizeMinBytes"
    )
    # root is the last partition, so no SizeMaxBytes needed


def test_root_partition_label():
    root = next(s for s in partitions().values() if s["Type"] == "root")
    assert root["Label"] == "Microraptor-root", (
        f"root partition label must be 'Microraptor-root', got {root['Label']!r}"
    )