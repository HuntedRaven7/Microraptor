# Microraptor

> [!WARNING]
> you will NOT receive any support if you use this image as is this is only for Robin!
> I would suggest you use this as a base idea for your own image.

## Two images

| Image | Containerfile | Published as |
|---|---|---|
| Workstation | `Containerfile.workstation` | `microraptor` |
| Homelab | `Containerfile.homelab` | `microraptor-homelab` |

Both build from the same Hummingbird base at the same digest and share
`00-image-info.sh` and `90-cleanup.sh`.

```bash
just build-workstation    # or `just build` — workstation is the default
just build-homelab
```

The **workstation** image is the desktop one: MangoWM and Quickshell, ly as the
display manager, the OGC kernel and the NVIDIA driver, and Homebrew and Flatpak
for user-installed software.

The **homelab** image is a server node: no desktop, no compositor, no display
manager, and Hummingbird's own kernel rather than OGC. It adds [k0s](https://k0sproject.io)
for Kubernetes, the KubeStellar Console agent, fail2ban, tailscale, and WiFi —
including the 147 MB of Intel firmware that a node with an Intel card needs in
order to associate at all. sshd ships key-only. Neither k0s unit is enabled: a
node is a controller or a worker by decision, not by image.

Automatic updates are deliberately **off** on the homelab image. Every node runs
the same update policy at the same time, so a scheduled reboot would take the
whole cluster down at once. Rolling a cluster is an operator's job, one node at a
time — see [build/README.md](build/README.md) for what is enabled and why.

## What makes the workstation image different?

- This image was built with [Fedora Hummingbird](https://fedoraproject.org/wiki/Hummingbird) tech and the [Finpilot](https://github.com/projectbluefin/finpilot) base template!

- We ship MangoWC and Quickshell for the DE experience that you build yourself! (Yes I will take 15 Million for my rice :3)

- Packaging from the official [Fedora](https://fedoraproject.org) repos and the [Terra](https://terrapkg.com) repos!

- it *will* build all it's own packages at one point in time! (this was said at: `2026-10-05 12:37pm est`)

- OGC and Nvidia by default! 

## What makes the homelab image different?

- k0s, so a node is a whole Kubernetes distribution in one binary and there is no dependency graph to drift between nodes. No kubeadm: it has no Fedora package, and using it would mean a Kubernetes repository left enabled on every node in the cluster.

- The KubeStellar Console agent, pinned by digest. It is a **nightly** — upstream publishes no stable release — so the pin is manual and the comment at it says so. See [build/README.md](build/README.md).

- fail2ban with firewalld, because fail2ban writes a drop-in that firewalld reads, and without firewalld running it bans nothing while appearing to work. 


## References.

### Bluefin!
- [Project Bluefin's Utah!](https://github.com/projectbluefin/utah)
- [Project Bluefin's Utah packages facotry](https://github.com/projectbluefin/utah-packages)

### Base Image Template
- [Project Bluefin's Finpilot!](https://github.com/projectbluefin/finpilot)

### Akmods
- [Ublue Akmods for OGC](https://github.com/ublue-os/akmods)


Thank you for checking this out!
