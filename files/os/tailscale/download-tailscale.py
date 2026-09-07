#!/usr/bin/env python3
"""Download and install the Tailscale client binary."""
import os
import tarfile
import urllib.request

url = os.environ["TAILSCALE_URL"]
with urllib.request.urlopen(url) as resp:
    data = resp.read()
with open("/tmp/tailscale.tgz", "wb") as f:
    f.write(data)
with tarfile.open("/tmp/tailscale.tgz", "r:gz") as tar:
    tar.extractall("/tmp")
os.chmod("/tmp/tailscale", 0o755)
os.chmod("/tmp/tailscaled", 0o755)
