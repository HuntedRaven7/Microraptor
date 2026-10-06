#!/usr/bin/env bash

set -euo pipefail

###############################################################################
# Homelab server: k0s
#
# k0s is a Kubernetes distribution in one static binary: the apiserver, etcd,
# kubelet, kube-proxy, containerd, CNI and the scheduler are all inside it, and
# `k0s controller` starts a cluster from that one file. This is why it is here
# rather than kubeadm, which is the other obvious answer:
#
#   kubeadm is the upstream path and it is what most people mean. It is not
#   available on this base: kubeadm, kubelet and kubectl have no Fedora package
#   at all -- src.fedoraproject.org/rpms/kubeadm does not exist, and only cri-o
#   is packaged. Using it means enabling pkgs.k8s.io, which has to stay enabled
#   on every node for the life of the cluster so kubelet can be updated. That is
#   a third-party repository shipped live on every node in a cluster, which is
#   the outcome 90-cleanup.sh exists to prevent.
#
#   k0s needs no repository and has no package. It is a file this script fetches,
#   verifies, and puts in /opt.
#
# 263 MB installed. Said out loud because it is the single largest thing in this
# image by a wide margin, and the reader deciding whether to accept it should not
# have to discover the number in a build log. It is also the point: the same
# nodes run the same single file, and there is no dependency graph to drift
# between them.
#
# Install location is /opt/bin, which is why this image does not need the
# workstation's `/opt -> /var/opt` symlink treatment: that exists so /opt is
# writable for downstream consumers, and a build-time binary does not need a
# writable /opt to exist. /usr/local/bin would be the other candidate and would
# mean putting a 263 MB vendor binary in a distribution's own prefix.
###############################################################################

# dnf5_retry comes from this helper, which 20-server-base.sh and
# 20-packages-and-services.sh both source for the same reason. Sourced here too
# rather than relying on an earlier phase having run: the phase must not depend
# on shell state it does not own, and `source /ctx/build/dnf5-retry.sh` under
# `set -u` fails the build outright if the context is malformed rather than
# falling through to a missing-function error on the first transaction.
#
# shellcheck source=/dev/null
source /ctx/build/dnf5-retry.sh

echo "::group:: Install k0s from a pinned release binary"

# One variable derives the URL, so the version and the digest cannot disagree
# about which release is meant. Only the digest has to be recomputed on a bump,
# and upstream's sha256sums.txt can do it:
#
#   curl -fsSL "https://github.com/k0sproject/k0s/releases/download/v${k0s_version}/sha256sums.txt"
#   | grep -F "k0s-v${k0s_version}-${arch}"
#
# Per-architecture because the binary is architecture-specific and the two
# digests are unrelated. TARGETARCH is the podman/buildah automatic build arg and
# is "amd64" or "arm64" -- the GOARCH spelling, not the Debian one. An unknown
# value is a hard failure rather than a silent fallback to amd64, because a
# fallback would install a binary that cannot execute and the failure would
# surface as a mysterious exec format error on first boot of a node rather than
# as a build error.
k0s_version="1.36.4+k0s.1"
k0s_arch="${TARGETARCH:-amd64}"
case "${k0s_arch}" in
  amd64) k0s_sha256="18c304d53cdd70095e99c6b859b269b4fef0bb84579d7e7185271a9135694a31" ;;
  arm64) k0s_sha256="04f685c8c9c29262da64acf26fd928452f19d449ac58729592f686f915882319" ;;
  *)
    echo "::error::unsupported TARGETARCH '${k0s_arch}'; k0s ships linux-amd64 and linux-arm64" >&2
    exit 1
    ;;
esac

# The `+` in the version is a real character in a git tag, and GitHub's release
# download path needs it percent-encoded. ${VAR//+/%2B} rather than leaving it
# literal: an unencoded + in a URL path is a plus, not a space, so it happens to
# work -- but it is a coincidence, and the encoded form is the one GitHub documents.
k0s_tag="v${k0s_version//+/%2B}"
k0s_asset="k0s-v${k0s_version}-${k0s_arch}"
k0s_url="https://github.com/k0sproject/k0s/releases/download/${k0s_tag}/${k0s_asset}"

# curl is named explicitly. It is what fetches the binary, so leaving it to the
# base to happen to carry it is circular, and 20-server-base.sh installing it
# earlier in this build is not a guarantee this script can rely on alone.
dnf5_retry "${DNF5_RETRY_ATTEMPTS}" install -y curl

# /tmp is mounted as tmpfs by the Containerfile for this phase, so 263 MB never
# lands in a layer. Cleared on exit as well, because the trap is cheaper than
# trusting the mount to still be there.
k0s_tmpdir="$(mktemp -d)"
trap 'rm -rf "${k0s_tmpdir}"' EXIT
k0s_download="${k0s_tmpdir}/${k0s_asset}"

# Looped rather than left to curl's --retry, for the reason dnf5_retry exists:
# the GitHub release CDN 302s to a host that intermittently fails, and curl
# retries one request against one URL with no second host to fail over to.
# Downloaded to .part and renamed on success so an interrupted attempt can never
# be mistaken for a complete file by the digest check below.
k0s_fetched=0
for k0s_attempt in 1 2 3; do
  if curl --fail --location --silent --show-error \
    --retry 3 --retry-delay 5 \
    --output "${k0s_download}.part" \
    "${k0s_url}"; then
    mv "${k0s_download}.part" "${k0s_download}"
    k0s_fetched=1
    break
  fi
  echo "::warning::k0s fetch failed (attempt ${k0s_attempt}/3); retrying" >&2
  sleep $((k0s_attempt * 5))
done

if [[ "${k0s_fetched}" -ne 1 ]]; then
  echo "::error::could not fetch ${k0s_url} after 3 attempts" >&2
  exit 1
fi

# Verified before install, not after. The binary is not unpacked by an installer
# here, so the ordering matters less than it does for an RPM -- but the property
# being preserved is the same: a mismatch fails the build with the image
# unchanged.
#
# k0s publishes both a sha256sums.txt and a detached .sig per binary, and the
# signature is verified by cosign against cosign.pub from the same release. The
# digest alone is what this script checks, and that is a real gap worth naming:
# a digest pins *this* artifact, where a signature additionally proves the
# publisher holds a particular key. cosign is not in Fedora 44 under a name this
# phase can rely on being present, and adding a key-fetch-and-verify step for a
# binary whose digest is already pinned from the release page is a trade this
# image declines deliberately rather than accidentally.
if ! echo "${k0s_sha256}  ${k0s_download}" | sha256sum --check --strict -; then
  echo "::error::${k0s_asset} does not match the pinned digest" >&2
  echo "::error::recurring here means upstream republished the asset, or the URL is not what it was" >&2
  exit 1
fi

install -d -m0755 /opt/bin
install -m0755 "${k0s_download}" /opt/bin/k0s

# Proven to run, not merely to exist. `k0s version` is the cheapest command that
# links the whole 263 MB, so an exec-format mismatch or a truncated binary that
# somehow passed the digest fails here rather than on a node's first boot.
if ! /opt/bin/k0s version >/dev/null 2>&1; then
  echo "::error::/opt/bin/k0s is not runnable in this image" >&2
  exit 1
fi

echo "k0s ${k0s_version} (${k0s_arch}) installed to /opt/bin/k0s"

echo "::endgroup::"

echo "::group:: Install the k0s systemd units"

# Two units, and neither is enabled. The reason is written into each unit as a
# Condition, so the answer is on the node rather than only here.
#
# A cluster node is either a controller or a worker, and that is a property of the
# machine in the cluster, not of the image. The same image is both, so the unit
# that should run is chosen by the operator after the node is deployed:
#
#   systemctl enable --now k0scontroller.service   # control plane
#   systemctl enable --now k0sworker.service       # worker only
#
# The alternative -- enabling the controller because a single-node cluster is the
# common first case -- is how you get a three-node cluster that was assembled by
# three machines all believing they were the control plane.
#
# The sysconfig file is where the arguments live, mirroring projectbluefin/server's
# k0s sysext: /etc/sysconfig/k0s sets K0S_CONTROLLER_ARGS and K0S_WORKER_ARGS.
# The defaults here are single-node-with-worker, which is the correct thing for a
# one-machine homelab and the wrong thing for a cluster, so they are stated
# plainly and are meant to be edited.
install -d -m0755 /etc/sysconfig

cat >/usr/lib/systemd/system/k0scontroller.service <<'EOF'
[Unit]
Description=k0s - Kubernetes control plane
Documentation=https://docs.k0sproject.io
ConditionFileIsExecutable=/opt/bin/k0s
ConditionPathExists=!/etc/k0s/token
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Single-node control plane with a colocated worker. Edit /etc/sysconfig/k0s
# for a real cluster -- a shared controller needs --enable-worker removed and a
# token in /etc/k0s/token, which is what makes k0sworker.service refuse to start
# here and keeps two nodes from both claiming to be the control plane.
Environment="K0S_CONTROLLER_ARGS=--enable-worker --single --disable-components=helm,autopilot"
EnvironmentFile=-/etc/sysconfig/k0s
ExecStart=/opt/bin/k0s controller $K0S_CONTROLLER_ARGS

StartLimitIntervalSec=5min
StartLimitBurst=10
Restart=always
RestartSec=5s

Delegate=yes
KillMode=process
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

cat >/usr/lib/systemd/system/k0sworker.service <<'EOF'
[Unit]
Description=k0s - Kubernetes worker
Documentation=https://docs.k0sproject.io
ConditionFileIsExecutable=/opt/bin/k0s
ConditionPathExists=/etc/k0s/token
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
Environment="K0S_WORKER_ARGS=--disable-components=helm,autopilot"
EnvironmentFile=-/etc/sysconfig/k0s
ExecStart=/opt/bin/k0s worker $K0S_WORKER_ARGS

StartLimitIntervalSec=5min
StartLimitBurst=10
Restart=always
RestartSec=5s

Delegate=yes
KillMode=process
LimitNOFILE=1048576
LimitNPROC=infinity
LimitCORE=infinity
TasksMax=infinity
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/sysconfig/k0s <<'EOF'
# Managed by this image. Edit to change how the k0s units start.
#
# The defaults below are single-node: one machine that is both control plane and
# worker. For a real cluster, on the control plane:
#
#   K0S_CONTROLLER_ARGS="--disable-components=helm,autopilot"
#
# and create /etc/k0s/token holding a shared token. k0scontroller.service is
# conditioned on that token NOT existing and k0sworker.service on it existing,
# which is what keeps exactly one node claiming to be the control plane.
#
# On a worker:
#
#   K0S_WORKER_ARGS="--disable-components=helm,autopilot"
#
# plus /etc/k0s/config.yaml from `k0s create worker --config-out`.
K0S_CONTROLLER_ARGS="--enable-worker --single --disable-components=helm,autopilot"
K0S_WORKER_ARGS="--disable-components=helm,autopilot"
EOF

systemctl daemon-reload

echo "::endgroup::"