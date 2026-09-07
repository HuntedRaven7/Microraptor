#!/bin/sh
set -eu
URL="${TAILSCALE_URL}"
python3 - "$URL" <<'PY'
import sys, urllib.request
url = sys.argv[1]
with urllib.request.urlopen(url) as r, open('/tmp/tailscale.tgz','wb') as f:
    f.write(r.read())
PY
tar -xzf /tmp/tailscale.tgz -C /tmp
chmod 0755 /tmp/tailscale /tmp/tailscaled
