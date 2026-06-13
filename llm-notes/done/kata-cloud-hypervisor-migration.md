# Kata Containers + QEMU Migration Plan

## STATUS: WON'T DO

**Replacement plan:** `llm-notes/plans/incus-workstation-migration-plan.md`

Running a full mutable NixOS system (systemd init, home-manager user environment) inside a
Kata containers workload is not achievable with Kata as currently designed. The plan is closed.

---

## Why Not

### The core requirement conflicts with Kata's architecture

The goal was to run a mutable NixOS system where:

- systemd runs as PID 1 of the guest
- The nix store is writable (home-manager installs packages)
- systemd user services work (home-manager activations, background services)

Kata's design requires `kata-agent` to own and manage the cgroup for the container workload
for its entire lifetime — this is how Kata controls process execution, resource limits, and
container lifecycle from outside the VM. systemd's core responsibility as PID 1 is also to
own the cgroup hierarchy and move all processes into `init.scope`.

These two requirements are mutually exclusive. The result is a cgroup v2 `EBUSY` conflict:
kata-agent places the container processes in a cgroup on startup; systemd then attempts to
take ownership of that cgroup; kata-agent's held references cause `EBUSY`; systemd either
fails to start or behaves incorrectly for the remainder of the container's lifetime.

Workarounds (forcing cgroup v1, disabling systemd's cgroup management) fight against both
Kata's design intent and NixOS's assumptions about how systemd operates. They would produce
a system that is unreliable in ways that are difficult to predict and reproduce.

### This is not a supported Kata use case

Kata containers is designed to isolate stateless OCI application containers — a workload
where the container runtime owns the full process lifecycle. Running a mutable, stateful,
systemd-managed OS image as the container workload is explicitly outside this design space.
There are no documented success cases and no indication the Kata project intends to support
this pattern.

### Relevant upstream issues

- **cgroup v2 conflict between kata-agent and systemd:**
  https://github.com/kata-containers/kata-containers/issues/10733

- **systemd as container entrypoint exits with status 255 (no resolution):**
  https://github.com/kata-containers/kata-containers/discussions/7357

---

## Background: What Was Explored

The original goal was to migrate from Incus (LXC containers + QEMU VMs) to a solution
providing VM-level kernel isolation per workload, managed declaratively from NixOS.

The evaluation path was:

1. **Incus + cloud-hypervisor** — rejected; cloud-hypervisor is unsupported and not planned
   in Incus. https://github.com/lxc/incus/issues/2167

2. **microvm.nix + cloud-hypervisor** — rejected; the mutable Nix store overlay breaks
   frequently when the underlying read-only store layer changes.
   https://github.com/microvm-nix/microvm.nix/issues/134

3. **Kata containers + QEMU (Podman)** — rejected; running a full systemd OS as the
   container workload is architecturally incompatible with Kata, is an unsupported use case,
   and has unresolved open issues with no path to resolution.

---

## What Remains Open

The underlying goal — VM-level isolation for mutable NixOS dev environments, declaratively
managed — has no clean solution identified. Options not yet fully evaluated:

- **microvm.nix with the overlay issue accepted or worked around** — the issue is real but
  may be tolerable for workloads that don't frequently change the underlying system.

- **A different VM manager that natively supports mutable NixOS guests** — e.g., libvirt
  with QEMU/KVM, managed declaratively. More operational complexity than microvm.nix but
  no overlay issue, and no cgroup ownership conflict.

- **Waiting for upstream resolution** — if the Kata cgroup issue is resolved, the plan
  could be revisited. Monitor https://github.com/kata-containers/kata-containers/issues/10733
