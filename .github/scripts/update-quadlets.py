#!/usr/bin/env python3
"""Update podman quadlet image versions from include/quadlets.yml.

This script reads version pins from include/quadlets.yml, substitutes them
into the quadlet templates, and writes the final quadlet files.

Usage:
    python3 .github/scripts/update-quadlets.py [--pihole TAG] [--hermes TAG] [--glance TAG] [--vaultwarden TAG]
"""

import argparse
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
QUADLETS_YML = ROOT / "include" / "quadlets.yml"
TEMPLATES_DIR = ROOT / "files" / "os" / "containers" / "systemd" / "templates"
OUTPUT_DIR = ROOT / "files" / "os" / "containers" / "systemd"

IMAGE_MAP = {
    "pihole": "pihole-image",
    "hermes": "hermes-image",
    "glance": "glance-image",
    "vaultwarden": "vaultwarden-image",
}


def parse_args():
    parser = argparse.ArgumentParser(description="Update quadlet image versions")
    parser.add_argument("--quadlets-file", default=QUADLETS_YML, type=Path)
    parser.add_argument("--templates-dir", default=TEMPLATES_DIR, type=Path)
    parser.add_argument("--output-dir", default=OUTPUT_DIR, type=Path)
    for name, var in IMAGE_MAP.items():
        parser.add_argument(f"--{name}", default=None, help=f"Override {var} tag")
    return parser.parse_args()


def read_versions(quadlets_file, overrides):
    text = quadlets_file.read_text()
    versions = {}
    for name, var in IMAGE_MAP.items():
        match = re.search(rf"^\s*{var}:\s*[\"]([^\"]+)[\"]", text, re.MULTILINE)
        if not match:
            sys.exit(f"ERROR: {var} not found in {quadlets_file}")
        versions[name.upper() + "_IMAGE"] = match.group(1)
    for name, tag in overrides.items():
        if tag:
            versions[name.upper() + "_IMAGE"] = tag
    return versions


def generate_quadlets(templates_dir, output_dir, versions):
    output_dir.mkdir(parents=True, exist_ok=True)
    for tmpl in templates_dir.glob("*.container"):
        content = tmpl.read_text()
        for var, value in versions.items():
            content = content.replace("{{" + var + "}}", value)
        out = output_dir / tmpl.name
        out.write_text(content)
        print(f"Generated {out}")


def update_quadlets_yml(quadlets_file, overrides):
    text = quadlets_file.read_text()
    for name, var in IMAGE_MAP.items():
        tag = overrides.get(name)
        if tag:
            text = re.sub(
                rf"^(\s*{var}:\s*[\"])[^\"]+([\"])",
                rf"\g<1>{tag}\2",
                text,
                count=1,
                flags=re.MULTILINE,
            )
    quadlets_file.write_text(text)
    print(f"Updated {quadlets_file}")


def main():
    args = parse_args()
    overrides = {
        name: getattr(args, name)
        for name in IMAGE_MAP
    }
    versions = read_versions(args.quadlets_file, overrides)
    generate_quadlets(args.templates_dir, args.output_dir, versions)
    if any(overrides.values()):
        update_quadlets_yml(args.quadlets_file, overrides)
    print("Quadlet versions updated successfully.")


if __name__ == "__main__":
    main()
