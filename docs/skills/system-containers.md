---
name: system-containers
description: Running systemd-nspawn toolboxes.
metadata:
  type: how-to
  status: stable
  last_updated: 2026-07-20
---
# System Containers

## When to Use

- Running `systemd-nspawn` toolboxes.
- System container operation with `machinectl`.

## When NOT to Use

- Production container workloads.

## Usage

```bash
# Start a system container
system-container start my-container

# Enter a running container
system-container enter my-container

# Stop a running container
system-container stop my-container

# Remove a container and its state
system-container reset my-container
```

## Verification

- [ ] `machinectl list` shows the expected containers.
- [ ] `system-container enter <name>` opens a shell in the container.
