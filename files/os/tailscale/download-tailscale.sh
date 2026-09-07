#!/bin/sh
set -eu
URL="${TAILSCALE_URL}"
wget -q -O /tmp/tailscale.tgz "${URL}"
tar -xzf /tmp/tailscale.tgz -C /tmp
chmod 0755 /tmp/tailscale /tmp/tailscaled
