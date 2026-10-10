#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Homelab server: kc-agent, the KubeStellar Console agent
#
# kc-agent is the local half of the KubeStellar Console: a binary that serves the
# console UI and turns a browser session into a kubeconfig, so the console talks
# to a cluster on this machine rather than to a hosted one.
#
# ############################################################################
# # READ THIS BEFORE UPDATING THE PIN
# #
# # This artifact is a NIGHTLY and there is no stable release. Every tag in
# # kubestellar/console looks like v0.3.43-nightly.YYYYMMDD, published daily and
# # marked prerelease. The version below was published on the day this phase was
# # written.
# #
# # That was a deliberate choice, taken with the cost understood: pinning it here
# # means the image ships a prerelease that upstream will never patch, and
# # keeping it current is a manual bump with no upstream signal about when it
# # matters. The alternative -- leaving kc-agent to Homebrew via the
# # kubestellar/tap, which is how projectbluefin/server consumes it -- tracks
# # upstream automatically but leaves the console absent until a user runs brew.
# #
# # What is pinned is the artifact, and the tags are dated so the pin does not rot
# # on its own: v0.3.43-nightly.20261006 will not be replaced. Bumping means
# # picking a newer dated tag and recomputing the digest:
# #
# #   curl -fsSL "<release-url>" | sha256sum
# #
# # There is no sha256sums.txt. The digests below were taken from the GoReleaser
# # output in kubestellar/homebrew-tap (Formula/kc-agent.rb) and then confirmed
# # against the artifacts themselves, because a digest copied out of a formula
# # that was generated at a different moment is not a verified digest.
# ############################################################################
#
# Requires k0s from 30-k0s.sh: kc-agent is a kubeconfig-to-browser bridge and has
# nothing to attach to without a cluster. It is a separate phase so that the
# dependency is in the Containerfile's ordering rather than implied.
###############################################################################

# Sourced for dnf5_retry, for the reason 30-k0s.sh gives: a phase should not
# depend on shell state an earlier phase happened to leave behind.
#
# shellcheck source=/dev/null
source /ctx/build/dnf5-retry.sh

echo "::group:: Install kc-agent from a pinned nightly"

kc_version="0.3.43-nightly.20261006"
kc_arch="${TARGETARCH:-amd64}"
case "${kc_arch}" in
  amd64) kc_sha256="dd72c2e1b63343ea70a6bd86f02503d5b4f4c634d444d5dc0bc775fdc0af9ddc" ;;
  arm64) kc_sha256="66fea56e778d395e9c1137dd0993f6285c22e7854da7b6eb5ff9f725f2076c9e" ;;
  *)
    echo "::error::unsupported TARGETARCH '${kc_arch}'; kc-agent ships linux-amd64 and linux-arm64" >&2
    exit 1
    ;;
esac

kc_asset="kc-agent_${kc_version}_linux_${kc_arch}.tar.gz"
kc_url="https://github.com/kubestellar/console/releases/download/v${kc_version}/${kc_asset}"

dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y curl

kc_tmpdir="$(mktemp -d)"
trap 'rm -rf "${kc_tmpdir}"' EXIT
kc_download="${kc_tmpdir}/${kc_asset}"

kc_fetched=0
for kc_attempt in 1 2 3; do
  if curl --fail --location --silent --show-error \
    --retry 3 --retry-delay 5 \
    --output "${kc_download}.part" \
    "${kc_url}"; then
    mv "${kc_download}.part" "${kc_download}"
    kc_fetched=1
    break
  fi
  echo "::warning::kc-agent fetch failed (attempt ${kc_attempt}/3); retrying" >&2
  sleep $((kc_attempt * 5))
done

if [[ "${kc_fetched}" -ne 1 ]]; then
  echo "::error::could not fetch ${kc_url} after 3 attempts" >&2
  exit 1
fi

if ! echo "${kc_sha256}  ${kc_download}" | sha256sum --check --strict -; then
  echo "::error::${kc_asset} does not match the pinned digest" >&2
  exit 1
fi

# The tarball also carries CHANGELOG.md, README.md and a changelog.d/ directory
# of ~40 fragments; unpacking all of it into /usr/share would put a nightly's
# build scratch into the image for no benefit.
#
# The binary and the licence are extracted separately, and that is not a style
# choice. A single `tar -xzf ... kc-agent LICENSE` fails with
# "tar: LICENSE: Not found in archive" and a non-zero status if a nightly ever
# stops shipping the licence, taking the binary down with it -- so a missing
# licence becomes a failed build rather than a warning, and the only thing the
# error names is the member. Both are named explicitly so a nightly that adds a
# top-level directory cannot quietly grow the image.
kc_extract="${kc_tmpdir}/extract"
mkdir -p "${kc_extract}"

# Required. No guard: without the binary there is nothing to install.
tar -xzf "${kc_download}" -C "${kc_extract}" kc-agent

install -d -m0755 /opt/bin
install -m0755 "${kc_extract}/kc-agent" /opt/bin/kc-agent

# Best effort. LICENSE is the one thing here that is a legal obligation rather
# than a convenience, so its absence is worth a warning -- but a warning, not a
# failed build over a file the image can still function without.
install -d -m0755 /usr/share/licenses/kc-agent
if ! tar -xzf "${kc_download}" -C "${kc_extract}" LICENSE 2>/dev/null; then
  echo "::warning::${kc_asset} carries no LICENSE; /usr/share/licenses/kc-agent will be empty" >&2
  echo "::warning::this is an upstream packaging change, not a digest mismatch" >&2
else
  install -m0644 "${kc_extract}/LICENSE" /usr/share/licenses/kc-agent/LICENSE
fi

# Same check as k0s: prove it runs rather than proving the file exists. kc-agent
# links Node's runtime into the binary, so this catches an exec-format mismatch
# and a truncated download that somehow passed the digest.
if ! /opt/bin/kc-agent --version >/dev/null 2>&1; then
  echo "::error::/opt/bin/kc-agent is not runnable in this image" >&2
  exit 1
fi

echo "kc-agent ${kc_version} (${kc_arch}) installed to /opt/bin/kc-agent"

echo "::endgroup::"

echo "::group:: Install the kc-agent units"

# Not enabled, and the reason is not the usual "the user has to configure it
# first". kc-agent's serve command needs a kubeconfig to bridge to, so starting
# it before k0s is running would start a console with no cluster behind it. The
# unit below is conditioned on a kubeconfig existing, which means enabling it
# ahead of a cluster is inert rather than broken.
install -d -m0755 /etc/systemd/system

cat >/usr/lib/systemd/system/kc-agent.service <<'EOF'
[Unit]
Description=KubeStellar Console agent
Documentation=https://github.com/kubestellar/console
ConditionFileIsExecutable=/opt/bin/kc-agent
# Inert until there is something to bridge to. This is what keeps "enable it
# before the cluster exists" from producing a console that serves nothing.
ConditionPathExists=/etc/k0s/kubeconfig.yaml
After=k0scontroller.service k0sworker.service network-online.target
Wants=network-online.target

[Service]
Type=simple
EnvironmentFile=-/etc/sysconfig/kc-agent
ExecStart=/opt/bin/kc-agent serve --kubeconfig /etc/k0s/kubeconfig.yaml $KC_AGENT_ARGS
Restart=on-failure
RestartSec=5s

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/sysconfig/kc-agent <<'EOF'
# Managed by this image. Edit to change how kc-agent serves the console.
#
# Left empty on purpose: kc-agent picks its own listen address and port, and
# writing a guessed --port here would override a default that upstream chooses
# for a reason. Add flags here if you want to pin them.
KC_AGENT_ARGS=""
EOF

# A systemd preset rather than a bare enable, so an operator who has not made a
# decision gets a running console instead of no console -- which is the whole
# point of shipping it. `systemctl mask kc-agent.service` is the opt-out.
#
# The drop-in directory is created explicitly because nothing else would. The unit
# above is written by `cat >` rather than by a package, and systemd only creates a
# .service.d/ directory when something installs a unit into an existing one -- so
# writing into it without this line fails the build with a bare "No such file or
# directory" that reads like a typo in the path rather than a missing mkdir.
install -d -m0755 /usr/lib/systemd/system/kc-agent.service.d

cat >/usr/lib/systemd/system/kc-agent.service.d/10-microraptor.preset <<'EOF'
enable kc-agent.service
EOF

# No `systemctl daemon-reload`, for the reason 30-k0s.sh gives at length: there is
# no systemd as PID 1 in a build container, so there is nothing to reload and the
# command fails the build on a phase that has already done its work.

echo "::endgroup::"