# Replace nerdctl inspect with containerd API + CNI state

## Problem

`deployd-exec inspect` uses `nerdctl inspect` to get container IPs. nerdctl v2
has rootful/rootless namespace confusion that causes it to fail even when run as
root via sudo. This has been an ongoing source of bugs (5+ commits of tweaks).
Additionally, the nerdctl inspect path requires `AF_NETLINK` in the service's
`RestrictAddressFamilies` and a `/var/lib/nerdctl` tmpfiles rule.

## Solution

Replace `nerdctl inspect` in the `deployd-exec` shell script with:

1. **`ctr`** (containerd's native CLI) to query the containerd gRPC API for the
   container ID by nerdctl name label
2. **CNI host-local state file scan** to find the IP assigned to that container

`ctr` is a direct gRPC client to containerd — no rootful/rootless confusion,
no nerdctl data store dependency. The CNI host-local IPAM plugin stores IP
allocations as plain files at `/var/lib/cni/networks/<network>/<ip>`, each
containing the container ID.

### Flow

```
deployd-helper → sudo deployd-exec inspect <name>
  → ctr -n default containers ls -q 'labels."nerdctl/name"==<name>'
  → get container ID
  → scan /var/lib/cni/networks/<bridge>/* for matching container ID
  → output IP
```

### Why not a Rust gRPC client?

The `containerd-client` crate requires tokio (async runtime). deployd-helper is
intentionally synchronous. Adding a full async runtime for one operation is
disproportionate.

## Changes

### deployd-exec (modules/deployd/default.nix)

- Replace `inspect` subcommand: `nerdctl inspect` → `ctr` + CNI state scan
- Add `ctrPath` variable alongside existing `nerdctlPath` and `systemctlPath`
- nerdctl is still used in systemd units for `run`/`stop`/`rm` (no change)

### Cleanup

- Remove `/var/lib/nerdctl` tmpfiles rule (was only needed for nerdctl inspect
  mount namespace; nerdctl run creates it as root in systemd units)
- Remove `AF_NETLINK` from `RestrictAddressFamilies` (nerdctl was the consumer;
  ctr uses only AF_UNIX for gRPC; sudo child may not inherit seccomp anyway)

### deployd-helper (Rust)

- No changes to executor.rs (still calls deployd-exec inspect, just gets
  different underlying implementation)
- Config: no changes (deployd_exec_path still used)

### VM test enhancement

Add a test that:

1. Pre-loads a minimal container image (busybox via containerd)
2. Runs a container via nerdctl (simulating what deployd systemd units do)
3. Sends an Inspect command through the deployd-helper socket
4. Verifies the response contains a valid IP from the bridge subnet

## Verification

1. `nix build .#checks.x86_64-linux.deployd` — test passes
2. Existing cc-sandbox create/inspect workflow works on erebonia
