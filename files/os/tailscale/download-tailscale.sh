#!/bin/sh
set -eu
URL="${TAILSCALE_URL}"
curl -fsSL -o /tmp/tailscale.tgz "${URL}"
tar -xzf /tmp/tailscale.tgz -C /tmp
chmod 0755 /tmp/tailscale /tmp/tailscaled
