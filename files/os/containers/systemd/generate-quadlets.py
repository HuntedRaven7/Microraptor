#!/usr/bin/env python3
import re
import sys
from pathlib import Path

ROOT = Path(".")
quadlets_yml = ROOT / "quadlets.yml"
templates_dir = ROOT / "templates"
target_dir = Path("%{install-root}") / "usr/lib/containers/systemd"
target_dir.mkdir(parents=True, exist_ok=True)

versions = {}
text = quadlets_yml.read_text()
for name, image in re.findall(r"^\s*([a-z_]+)-image:\s*[\"]([^\"]+)[\"]", text, re.MULTILINE):
    versions[name.upper() + "_IMAGE"] = image

for tmpl in templates_dir.glob("*.container"):
    content = tmpl.read_text()
    for var, value in versions.items():
        content = content.replace("{{" + var + "}}", value)
    out = target_dir / tmpl.name
    out.write_text(content)
    print(f"Generated {out}")
