# Incus VM Migration Plan

Achieves kernel isolation for all Incus-managed instances with minimal changes to the
existing Incus setup. Supersedes the Kata containers approach; see prior research at
`llm-notes/plans/kata-cloud-hypervisor-migration.md`.

---

## Summary of Changes

1. **Convert messeldam from LXC container to Incus VM** — the only instance still running
   with a shared kernel. trista is already an Incus VM and needs no type change.

2. **Fix the system update mechanism** — the current `incus exec nixos-rebuild switch`
   approach has a latent bug: it requires the NixOS flake source to be available inside the
   instance, which it isn't. Replace with host-side build + SSH activation.

3. **Adopt the home-manager user environment model** — document the intended layering:
   the NixOS system config is the fixed base; home-manager is the everyday update path for
   user tooling. Applies to both instances.

---

## Current State

| Instance  | Host     | Type            | Kernel isolation          |
| --------- | -------- | --------------- | ------------------------- |
| messeldam | calvard  | LXC container   | None (shared host kernel) |
| trista    | erebonia | Incus VM (QEMU) | Yes                       |

After this migration both instances are Incus VMs.

---

## Change 1: messeldam LXC → Incus VM

### messeldam/default.nix and trista/default.nix — add authorized keys

Both guest configs currently have `services.openssh` enabled with `PermitRootLogin =
"prohibit-password"` but **no authorized keys configured**. This has been harmless because
the current `incus exec` update mechanism goes through the Incus socket, not SSH. But
`nixos-rebuild --target-host` requires SSH access — it will fail immediately without this.

Replace the manual `services.openssh` block in each guest with `common.openssh`:

```nix
# hosts/calvard/containers/messeldam/default.nix
common.openssh = {
  enable = true;
  keys = [ "deploy" "calvard" ];  # deploy key for manual ops; calvard host key for automated updates
};

# hosts/erebonia/containers/trista/default.nix
common.openssh = {
  enable = true;
  keys = [ "deploy" "erebonia" ];  # deploy key for manual ops; erebonia host key for automated updates
};
```

`common.openssh` accesses `pkgs.mmell.lib.data.keys`, which comes from the project overlay.
This is why the guests must be built via `mk-nixos` (or an equivalent that applies the
overlays) rather than a bare `nixpkgs.lib.nixosSystem` call — see the flake.nix section below.

### calvard/default.nix — SSH client identity for nixos-rebuild

`nixos-rebuild --target-host` on calvard uses the root SSH client. Calvard's root has no
user-level SSH key (`~/.ssh/id_*`) — its host key is only used explicitly in git config
(`-i /etc/ssh/ssh_host_ed25519_key`). Without configuration, `nixos-rebuild --target-host
root@messeldam` will fail to authenticate.

Add an SSH client config in calvard's NixOS config:

```nix
# hosts/calvard/default.nix
programs.ssh.extraConfig = ''
  Host messeldam
    Hostname 10.97.20.42
    User root
    IdentityFile /etc/ssh/ssh_host_ed25519_key
    IdentitiesOnly yes
'';
```

`Hostname` uses the IP directly rather than relying on DNS, which may not be available
during system activation. erebonia needs the equivalent for trista:

```nix
# hosts/erebonia/default.nix
programs.ssh.extraConfig = ''
  Host trista
    Hostname 10.97.100.51
    User root
    IdentityFile /etc/ssh/ssh_host_ed25519_key
    IdentitiesOnly yes
'';
```

### calvard/incus.nix

Move messeldam from `containers` to `virtualMachines`, and update the `dev` profile:

```nix
profiles = {
  dev = {
    description = "Development VM profile";
    config = {
      "limits.cpu" = "4";
      "limits.memory" = "4GB";
      "security.privileged" = "false";
      # Remove security.nesting — only needed for Docker-in-LXC.
      # VMs can run Docker natively without it.
    };
    devices = {
      root = {
        path = "/";
        pool = "default";
        type = "disk";
        size = "50GB";
      };
    };
  };
};

# Remove from containers:
# containers = { messeldam = { ... }; };

# Add to virtualMachines:
virtualMachines = {
  messeldam = {
    configurationFile = ./containers/messeldam;
    autoUpdate = true;
    profile = "dev";
    network = "incusbr20";
    autoStart = true;
  };
};
```

### messeldam/default.nix — interface name

Incus VMs present the network interface as `enp5s0` (virtio-net on a predictable PCI slot),
which matches the current guest config. No change required.

### flake.nix — add messeldam and trista as nixosConfiguration outputs

Both guests need to be named flake outputs. Use `lib.mk-nixos` directly — it is appropriate:

- The overlays it applies are **required**: `common.openssh` accesses `pkgs.mmell.lib.data.keys`
- `nixosModules.common` adds only opt-in options (all guarded by `mkIf cfg.enable`) — no conflict
- `sops-nix.nixosModules.sops` is a no-op when no `sops.secrets` are defined — no conflict
- `nixosModules.promtail-client` is similarly opt-in

```nix
nixosConfigurations = {
  # ... existing hosts ...
  messeldam = self.lib.mk-nixos {
    inherit nixpkgs;
    system = "x86_64-linux";
    modules = [ ./hosts/calvard/containers/messeldam ];
  };
  trista = self.lib.mk-nixos {
    inherit nixpkgs;
    system = "x86_64-linux";
    modules = [ ./hosts/erebonia/containers/trista ];
  };
};
```

These outputs serve double duty: they are the source for both the initial image build (via
the incus-manager module change below) and the `--target-host` update target. This ensures
the image imported into Incus and the system activated by updates are always the same
derivation.

---

## Change 2: Fix the System Update Mechanism

### The problem

`modules/incus/default.nix` runs system updates as:

```bash
incus exec "$INSTANCE" -- nixos-rebuild switch
```

`nixos-rebuild switch` with no arguments needs either `/etc/nixos/configuration.nix` or a
flake reference inside the instance to know what to build. Neither exists — the guest configs
live on the host, not inside the VM. In practice this either fails silently or rebuilds to
whatever stale configuration the VM happens to have cached.

### The fix

Build on the host (where the flake lives), copy the closure to the VM over SSH, activate:

```bash
nixos-rebuild switch --flake .#"$INSTANCE" --target-host "$INSTANCE"
```

`nixos-rebuild --target-host` builds locally, copies the new system closure to the target
via `nix copy` over SSH, and runs `switch-to-configuration switch` remotely. SSH client
identity is handled by the `programs.ssh.extraConfig` entries added to calvard and erebonia
(see Change 1 above) — no extra flags needed in the update script.

### Module changes in modules/incus/default.nix

**Image build:** Replace the internal `nixosSystem` call in `mkVMImage` with a reference to
`self.nixosConfigurations.${name}`. This eliminates the separate image-build evaluation and
ensures the imported image and the update target are always the same derivation. The module
declares `self` as a parameter (it is already available via `mk-nixos`'s `specialArgs`):

```nix
{ config, pkgs, lib, self, ... }:

# Replace mkVMImage's internal nixosSystem with:
mkVMImage = name: pkgs.runCommand "${name}-vm-image" {} ''
  mkdir -p $out
  ln -s ${self.nixosConfigurations.${name}.config.system.build.metadata}/tarball/*.tar.xz \
    $out/metadata.tar.xz
  ln -s ${self.nixosConfigurations.${name}.config.system.build.qemuImage}/*.qcow2 \
    $out/disk.qcow2
'';
```

The `configurationFile` option on `virtualMachines` entries is no longer used for image
building — it becomes optional/unused for instances that have a matching
`nixosConfigurations` output. The `imagePackage` override escape hatch remains for any
instance that doesn't have a flake output.

**Update script:** Replace `mkUpdateScript` to use `nixos-rebuild --target-host`:

```bash
# Old:
${pkgs.incus}/bin/incus exec "$INSTANCE" -- nixos-rebuild switch

# New:
${pkgs.nixos-rebuild}/bin/nixos-rebuild switch \
  --flake "${cfg.flakePath}#$INSTANCE" \
  --target-host "$INSTANCE"
```

Add a `flakePath` option so the module knows where the flake lives at runtime:

```nix
options.incus-manager.flakePath = mkOption {
  type = types.path;
  description = ''
    Path to the flake containing nixosConfigurations for managed instances.
    Used by the update mechanism to build and activate new system generations.
  '';
  example = "/persist/dotfiles";
};
```

Set this in each host's incus config:

```nix
# hosts/calvard/incus.nix
incus-manager = {
  flakePath = "/persist/dotfiles";
  # ...
};
```

---

## Change 3: Home-Manager User Environment Model

This is a documentation/convention change, not a code change.

### Intended layering

```
Incus VM disk
  └─ NixOS base system  (networking, SSH, systemd, core packages)
       managed by: host nixos-rebuild → nixos-rebuild --target-host
       update cadence: infrequent (nixpkgs bumps, system config changes)

  └─ home-manager environment  (dev tools, shell, dotfiles, language envs)
       managed by: user running `home-manager switch` inside the VM
       update cadence: frequent, no interruption
```

The NixOS `default.nix` for each instance should include only what every user of that
instance needs (SSH, networking, nix itself, home-manager). User-specific tooling lives
in home-manager configs, not in the system config.

### Persistence

Incus VM disks are persistent by default — the writable disk survives restarts and image
updates (since VMs are updated in-place, not replaced like OCI containers). `/home` persists
naturally. No named-volume scheme is needed.

---

## Migration Steps

### Pre-flight

1. Confirm SSH access to messeldam from calvard as root:
   ```bash
   incus exec messeldam -- ssh root@messeldam  # or test from calvard directly
   ```
2. Confirm trista is similarly reachable for the update mechanism fix:
   ```bash
   ssh root@trista
   ```
3. Back up messeldam data (the LXC rootfs will be deleted):
   ```bash
   incus exec messeldam -- tar -czf /tmp/data.tar.gz /home /root
   incus file pull messeldam/tmp/data.tar.gz ./messeldam-backup.tar.gz
   ```

### Phase 1: Remove the LXC container

```bash
# On calvard
incus stop messeldam
incus delete messeldam
incus image delete messeldam   # remove old LXC image alias
```

### Phase 2: Update flake and host configs

1. Add `messeldam` and `trista` as `nixosConfigurations` outputs in `flake.nix` (using `mk-nixos`)
2. Update `hosts/calvard/containers/messeldam/default.nix`:
   - Replace `services.openssh` block with `common.openssh = { enable = true; keys = [ "deploy" "calvard" ]; }`
3. Update `hosts/erebonia/containers/trista/default.nix`:
   - Replace `services.openssh` block with `common.openssh = { enable = true; keys = [ "deploy" "erebonia" ]; }`
4. Update `hosts/calvard/default.nix`: add `programs.ssh.extraConfig` for messeldam
5. Update `hosts/erebonia/default.nix`: add `programs.ssh.extraConfig` for trista
6. Update `hosts/calvard/incus.nix`:
   - Move messeldam from `containers` to `virtualMachines`
   - Remove `security.nesting` from the `dev` profile
   - Add `incus-manager.flakePath`
7. Update `modules/incus/default.nix`:
   - Add `self` parameter
   - Replace internal `nixosSystem` image build with `self.nixosConfigurations.${name}`
   - Add `flakePath` option
   - Replace `mkUpdateScript` with the `nixos-rebuild --target-host` approach

### Phase 3: Deploy

```bash
nixos-rebuild switch --flake .#calvard --target-host calvard
```

The activation script builds the VM image (qcow2 via `incus-virtual-machine.nix`), imports
it, creates and starts the VM instance.

### Phase 4: Restore data

```bash
incus file push ./messeldam-backup.tar.gz messeldam/tmp/
incus exec messeldam -- tar -xzf /tmp/messeldam-data.tar.gz -C /
```

### Phase 5: Verify

```bash
# messeldam now has its own kernel
incus exec messeldam -- uname -r   # should differ from calvard's kernel

# Network reachability unchanged
ping -c1 10.97.20.42

# SSH
ssh messeldam

# Confirm update mechanism works
nixos-rebuild switch --flake .#messeldam --target-host root@messeldam
```

---

## What This Does Not Address

- **cloud-hypervisor**: Not available in Incus. QEMU remains the hypervisor. The attack
  surface difference is marginal for long-running VMs; see the Incus developer's argument
  in the prior research doc.

- **Rootless operation**: Incus requires root on the host. The `podman-runner` system user
  model from the Kata plan is not applicable here. Incus's own security model (AppArmor
  profiles, seccomp, unprivileged containers/VMs) provides the equivalent protection.
