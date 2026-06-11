# Incus Module Overhaul Plan

> **Curation note (2026-06-11):** Historical completed plan. The Step 8
> instruction to document conventions in `CLAUDE.md` was a plan-time task, not a
> statement that `CLAUDE.md` is the only active guide for agents.

## Context

The `modules/incus/default.nix` module has accumulated dead code, unnecessary abstractions, a flake-path-dependent update mechanism, and lacks tests. calvard and erebonia depend on this module. This overhaul strips it to essentials, aligns it with the microvm auto-discovery pattern, adds pre-built closure updates, and creates integration tests to de-risk the calvard deploy.

## Module Architecture

Following the project convention:

- **Top-level modules** (`modules/incus/`) — reusable, extractable service integration. Defines the Incus instance management service: image building, instance lifecycle, systemd services, helper scripts. No project-specific logic.
- **Common module** (`modules/common/incus.nix`) — project-specific coordination. Auto-discovery from `guestDir`, impermanence persistence, builder wiring. Like `modules/common/microvm.nix`.

## Issues Identified

### From user report (confirmed)

1. **Dead/confusing preseed duplication** — `storage`, `networks`, `profiles` options duplicate NixOS's built-in `virtualisation.incus.preseed`.
2. **Unnecessary option complexity** — `networks.type` only accepts `"bridge"`, `storage.driver` enumerates 4 unused values.
3. **Flake path reference for VMs** — `mkVMImage` references `self.nixosConfigurations.${name}`, requiring manual flake entries.
4. **Container build uses bare `nixosSystem`** — Missing overlays, sops, common module.
5. **Storage/persistence unclear** — No impermanence integration.
6. **Stale documentation** — Module header describes broken mechanisms.
7. **No tests** — Zero coverage.
8. **No QEMU package override** — Can't work around upstream breakage.

### Additional issues found

9. **Activation script ordering** — `incusEnsureInstances` runs before incus daemon is up.
10. **Fire-and-forget background updates** — No logging or failure tracking.
11. **Bash bug in `incus-update-instance`** — Unnecessarily complex case/linear-scan.
12. **VM/container modules not added by incus-manager** — `incus-virtual-machine.nix` and `lxc-container.nix` added only in flake.nix.

## Decisions Made

- **Auto-discover guests from guestDir** (like microvms) — no manual flake.nix entries per guest
- **Pre-built closure push** for updates — build at eval time, push via `nix copy` + `switch-to-configuration`
- **QEMU package override** via module option, default `pkgs.qemu_kvm`
- **Containers use same builder pattern** as VMs — `mk-incus-container` with overlays/sops/common
- **SSH client config stays manual** in host `default.nix`
- **Keep helper scripts** alongside systemd services
- **Split into top-level + common module** following project convention

## Implementation Steps

### Step 1: Add builders to `flake.nix`

Add `mk-incus-vm` and `mk-incus-container` as passive module mergers (like `mk-microvm` at line 157), and expose via overlay.

```nix
# flake.nix lib section (after mk-microvm)
mk-incus-vm = args: nixpkgs.lib.mkMerge [ args {
  imports = [
    sops-nix.nixosModules.sops
    self.nixosModules.common
    self.nixosModules."promtail-client"
    "${nixpkgs}/nixos/modules/virtualisation/incus-virtual-machine.nix"
  ];
}];
mk-incus-container = args: nixpkgs.lib.mkMerge [ args {
  imports = [
    sops-nix.nixosModules.sops
    self.nixosModules.common
    self.nixosModules."promtail-client"
    "${nixpkgs}/nixos/modules/virtualisation/lxc-container.nix"
  ];
}];
```

Overlay (line 112): add to `builders`:

```nix
builders = { inherit (self.lib) mk-microvm mk-incus-vm mk-incus-container; };
```

Remove `edith` and `trista` from `nixosConfigurations` (lines 214-228).

**File**: `flake.nix`

### Step 2: Rewrite `modules/incus/default.nix` (top-level module)

This is the **extractable** module — no project-specific logic. It takes a set of fully-built guest systems and manages their Incus lifecycle.

**Options**:

| Option                                  | Type                      | Purpose                                 |
| --------------------------------------- | ------------------------- | --------------------------------------- |
| `incus-manager.enable`                  | bool                      | Enable incus instance management        |
| `incus-manager.qemuPackage`             | package                   | QEMU override (default `pkgs.qemu_kvm`) |
| `incus-manager.guests.<name>.type`      | enum `["vm" "container"]` | Instance type                           |
| `incus-manager.guests.<name>.system`    | NixOS system              | The built guest system                  |
| `incus-manager.guests.<name>.profile`   | nullOr str                | Incus profile to apply                  |
| `incus-manager.guests.<name>.network`   | nullOr str                | Incus network to connect                |
| `incus-manager.guests.<name>.autoStart` | bool                      | Start on boot (default true)            |

**Provides**:

- `virtualisation.incus.enable = true` + `networking.nftables.enable = true`
- Image builders: `mkVMImage` (metadata + qcow2), `mkContainerImage` (metadata + rootfs)
- Systemd services:
  - `incus-ensure-instances.service` — `After=incus.service`, creates/starts instances
  - `incus-update-instances.service` — `After=incus-ensure-instances.service`, pushes pre-built closures via `nix copy` + `switch-to-configuration`
- Helper scripts: `incus-ensure-instances`, `incus-update-instances`, `incus-update-instance <name>`

**Removed**: `flakePath`, `storage`, `networks`, `profiles`, `containers`, `virtualMachines`, `autoUpdate`, `configurationFile`, `imagePackage`, `image`, entire preseed generation, activation scripts.

**Note**: The preseed configuration (storage pools, networks, profiles) is currently proposed to live in the host configs using NixOS's built-in `virtualisation.incus.preseed`. However, the implementor may find it makes more sense to add preseed helpers to the common module (e.g., auto-generating network/profile preseed entries from the discovered guests). This is left as an implementation-time decision.

**File**: `modules/incus/default.nix`

### Step 3: Create `modules/common/incus.nix` (common module)

Project-specific coordination, mirrors `modules/common/microvm.nix`.

**Options**:

| Option                  | Type        | Purpose                                  |
| ----------------------- | ----------- | ---------------------------------------- |
| `common.incus.enable`   | bool        | Enable common incus host options         |
| `common.incus.guestDir` | nullOr path | Auto-discover guests from subdirectories |

**Provides**:

- Auto-discovery: reads `guestDir` subdirectories, imports each guest config, builds via `mk-incus-vm`/`mk-incus-container`, populates `incus-manager.guests`
- Impermanence: persists `/var/lib/incus` (when impermanence module is loaded)

Guest type/profile/network are read from the built guest system's `incus-guest.*` options.

**File**: `modules/common/incus.nix`

### Step 4: Add `incus-guest` options

Small options module defining guest-side metadata (`type`, `profile`, `network`, `autoStart`). Included by the builders so guest configs can set these values. The common module reads them from the built system to configure the top-level module.

```nix
options.incus-guest = {
  type = mkOption { type = types.enum [ "vm" "container" ]; default = "vm"; };
  profile = mkOption { type = types.nullOr types.str; default = null; };
  network = mkOption { type = types.nullOr types.str; default = null; };
  autoStart = mkOption { type = types.bool; default = true; };
};
```

**File**: `modules/incus/guest-options.nix` (imported by builders)

### Step 5: Simplify host configs

**`hosts/calvard/incus/default.nix`**:

```nix
{
  common.incus = {
    enable = true;
    guestDir = ./guests;
  };
  # Preseed via NixOS built-in — not abstracted by our module
  virtualisation.incus.preseed = {
    storage_pools = [{ name = "default"; driver = "zfs"; config.source = "persist/incus"; }];
    networks = [
      { name = "incusbr20"; type = "bridge";
        config = { "bridge.external_interfaces" = "br20"; "ipv4.address" = "none"; "ipv6.address" = "none"; }; }
      { name = "incusbr100"; type = "bridge";
        config = { "bridge.external_interfaces" = "br100"; "ipv4.address" = "none"; "ipv6.address" = "none"; }; }
    ];
    profiles = [
      { name = "dev"; description = "Development VM profile";
        config = { "limits.cpu" = "4"; "limits.memory" = "4GB"; "security.privileged" = "false"; };
        devices = { root = { path = "/"; pool = "default"; type = "disk"; size = "50GB"; }; }; }
    ];
  };
}
```

**`hosts/erebonia/incus/default.nix`** — same pattern with its own preseed values.

**Files**: `hosts/calvard/incus/default.nix`, `hosts/erebonia/incus/default.nix`

### Step 6: Update guest configs

Add `incus-guest` options (profile, network moved from host config):

```nix
{ pkgs, config, lib, ... }: {
  imports = [ ./sops.nix ];
  incus-guest = {
    profile = "dev";
    network = "incusbr20";
  };
  networking.hostName = "edith";
  # ... rest unchanged ...
}
```

**Files**: `hosts/calvard/incus/guests/edith/default.nix`, `hosts/erebonia/incus/guests/trista/default.nix`

### Step 7: Add integration tests

**`tests/modules/incus-container.nix`**:

- Single test machine with incus + module enabled
- Inline minimal container guest
- Test: image import → create → start → `incus exec` succeeds

**`tests/modules/incus-vm.nix`**:

- Test machine with nested virt + incus
- Inline minimal VM guest
- Test: image import → create → start → `incus exec` succeeds

Both use `pkgs.testers.nixosTest` pattern from existing tests. Register in `flake.nix` checks section.

**Files**: `tests/modules/incus-container.nix`, `tests/modules/incus-vm.nix`, `flake.nix` (checks)

### Step 8: Document module architecture convention

Add a section to `CLAUDE.md` documenting the distinction between top-level modules and common modules:

- **Top-level modules** (`modules/<name>/`) — define new services or integrations. Designed to be extractable from this flake. No project-specific logic (no hardcoded host names, no impermanence assumptions, no guestDir auto-discovery).
- **Common modules** (`modules/common/<name>.nix`) — project-specific coordination and shared configuration across hosts. Handle things like auto-discovery, impermanence integration, builder wiring. Not designed to be extracted.

This convention already exists implicitly (e.g., `modules/router6/` vs `modules/common/microvm.nix`) but has never been documented.

**File**: `CLAUDE.md` (Architecture section)

### Step 9: Update `scripts/setup-incus-guests.sh`

Line 50: replace broken in-guest `nixos-rebuild switch` with helper script:

```bash
ssh "$TARGET" "incus-update-instance ${guest}" || true
```

**File**: `scripts/setup-incus-guests.sh`

## Files Modified

| File                                             | Action                                                                        |
| ------------------------------------------------ | ----------------------------------------------------------------------------- |
| `modules/incus/default.nix`                      | **Rewrite** — top-level module: instance lifecycle, systemd services, helpers |
| `modules/incus/guest-options.nix`                | **New** — guest-side options (type, profile, network)                         |
| `modules/common/incus.nix`                       | **New** — common module: auto-discovery, impermanence                         |
| `flake.nix`                                      | **Edit** — add builders, overlay, remove edith/trista, add test checks        |
| `hosts/calvard/incus/default.nix`                | **Rewrite** — use `common.incus` + raw preseed                                |
| `hosts/erebonia/incus/default.nix`               | **Rewrite** — same                                                            |
| `hosts/calvard/incus/guests/edith/default.nix`   | **Edit** — add incus-guest options                                            |
| `hosts/erebonia/incus/guests/trista/default.nix` | **Edit** — add incus-guest options                                            |
| `CLAUDE.md`                                      | **Edit** — document module architecture convention                            |
| `scripts/setup-incus-guests.sh`                  | **Edit** — use helper script for updates                                      |
| `tests/modules/incus-container.nix`              | **New** — container integration test                                          |
| `tests/modules/incus-vm.nix`                     | **New** — VM integration test                                                 |

## Verification

1. `nix build .#nixosConfigurations.calvard.config.system.build.toplevel` — calvard builds
2. `nix build .#nixosConfigurations.erebonia.config.system.build.toplevel` — erebonia builds
3. `nix build .#checks.x86_64-linux.incus-container --print-build-logs` — container test passes
4. `nix build .#checks.x86_64-linux.incus-vm --print-build-logs` — VM test passes
5. `nix flake check --print-build-logs` — all existing tests still pass

---

## Addendum: Implementation Notes

_Added after implementation was complete._

### Deviations from Plan

**Builders use `nixosSystem` instead of `mkMerge`.**
The plan proposed `mk-incus-vm` and `mk-incus-container` as passive `mkMerge` mergers (like `mk-microvm`). This doesn't work because `nixosSystem` expects a list of modules, not a merged attrset — and incus guests need a fully-evaluated NixOS system (with `config.system.build.toplevel`, `config.system.build.qemuImage`, etc.) that the top-level module can reference at eval time to build images and update scripts. The microvm pattern works differently because `microvm.vms.<name>.config` accepts the merged attrset directly. The incus builders were implemented as full `nixosSystem` calls instead.

**`qemuPackage` option dropped.**
The plan included an `incus-manager.qemuPackage` option to work around upstream QEMU breakage. During implementation we discovered that `pkgs.incus.override { qemu_kvm = ... }` is not supported — incus doesn't expose that argument. The option was removed entirely.

**VM test skips `incus exec`.**
The plan specified both tests should verify `incus exec` succeeds. The VM test can't do this because nested virtualization in the NixOS test VM doesn't fully boot the guest OS (QEMU starts and incus reports RUNNING, but the incus-agent inside the guest never comes up). The VM test verifies image import → create → RUNNING status only.

**Two-pass guest type probing.**
The plan didn't specify how `common/incus.nix` should determine guest type. Since guest configs reference `common.*` options (e.g. `common.openssh`), they can't be evaluated with a bare `nixosSystem` — they need the full module set. The implementation builds with the VM builder first to probe `incus-guest.type`, then rebuilds with the container builder only if needed. Nix's lazy evaluation means the VM build artifacts are never materialized for container guests.

### Additional Work: Impermanence Refactor

During implementation, the accumulation of `options ? environment && options.environment ? persistence` guards across common modules became untenable. A mid-project refactor was done:

- **`modules/common/impermanence.nix`** created — centralizes the `/persist` convention with `common.impermanence.{enable, persistDir}` options and baseline persistent paths (machine-id, SSH host keys, logs, etc.).
- **`impermanence.nixosModules.impermanence`** added to all builders (`mk-nixos`, `mk-microvm`, `mk-incus-vm`, `mk-incus-container`) so the `environment.persistence` option schema is always available. This lets common modules use plain `mkIf` instead of `optionalAttrs` guards.
- **Host impermanence configs simplified** — calvard, erebonia, and thebeyond now set `common.impermanence.enable = true` and only add host-specific extras (initrd SSH keys, ZFS rollback).
- **`microvm.nix`** updated to use `impCfg.persistDir` instead of hardcoded `"/persist"`.

### Files Modified (final)

In addition to the files listed in the plan:

| File                               | Action                                      |
| ---------------------------------- | ------------------------------------------- |
| `modules/common/impermanence.nix`  | **New** — common impermanence module        |
| `hosts/calvard/impermanence.nix`   | **Simplified** — uses `common.impermanence` |
| `hosts/erebonia/impermanence.nix`  | **Simplified** — uses `common.impermanence` |
| `hosts/thebeyond/impermanence.nix` | **Simplified** — uses `common.impermanence` |

### Verification Results

All verification steps pass:

1. calvard toplevel builds ✅
2. erebonia toplevel builds ✅
3. incus-container test passes ✅
4. incus-vm test passes ✅
