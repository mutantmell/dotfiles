# Disko-based Incus VM Image Builder

## Problem

Incus VM images are built via nixpkgs' `make-disk-image.nix` (wrapped by
`incus-virtual-machine.nix`), which hardcodes ext4 when a partition table is
present. This caused a cascading failure on edith (Incus VM on calvard): disk
filled up → ext4 journal corruption → read-only filesystem → GC couldn't run →
VM unrecoverable, had to tear down and recreate.

XFS handles full-disk scenarios more gracefully (pre-allocated journal, returns
ENOSPC without corruption or forced read-only remount).

## Solution

Replace `incus-virtual-machine.nix` with disko's `system.build.diskoImages`.

`incus-virtual-machine.nix` is a thin wrapper (~60 lines) around:

- `qemu-guest.nix` (virtio kernel modules)
- `lxc-instance-common.nix` (Incus metadata tarball)
- `make-disk-image.nix` (ext4-only image builder)
- ~7 lines of boot/agent config

We import `qemu-guest.nix` and `lxc-instance-common.nix` directly, add the
~7 lines of boot config ourselves, and let disko own the disk layout and image
building entirely. This is validated — see eval test results below.

## Why Not Upstream `make-disk-image.nix`?

We initially considered an upstream PR to add XFS support to
`make-disk-image.nix`. The technical challenge is significant: ext4 uses a
special LKL tool (`cptofs -E offset=`) that formats and populates a partition
inside a raw image without needing a VM or loopback device. XFS has no
equivalent — formatting and copying would need to move into the VM phase.

More importantly, `make-disk-image.nix` itself has a comment directing
contributors toward unifying image builders (NixOS/nixpkgs#324817). The
`nixos/modules/virtualisation/` directory contains dozens of similar wrapper
files, most unchanged for 2+ years. These are static defaults for test VMs,
not actively maintained integration layers.

Disko's image builder (`system.build.diskoImages`) already solves this properly:
it runs inside a QEMU VM during the Nix build, supports arbitrary filesystems,
and is actively maintained. We already depend on disko for our physical hosts.

## Validated Eval Test

The following configuration was eval-tested and confirmed working with zero
conflicts (no `mkForce` needed):

```nix
modules = [
  # Direct imports (bypassing incus-virtual-machine.nix)
  "${nixpkgs}/nixos/modules/virtualisation/lxc-instance-common.nix"
  "${nixpkgs}/nixos/modules/profiles/qemu-guest.nix"
  disko.nixosModules.disko

  ({ pkgs, ... }: {
    # ~7 lines cherry-picked from incus-virtual-machine.nix
    boot.growPartition = true;
    boot.loader.systemd-boot.enable = true;
    boot.loader.grub.device = "/dev/vda";
    boot.kernelParams = [ "console=tty1" "console=ttyS0" ];
    services.udev.extraRules = ''
      SUBSYSTEM=="cpu", CONST{arch}=="x86-64", TEST=="online", ATTR{online}=="0", ATTR{online}="1"
    '';
    virtualisation.incus.agent.enable = lib.mkDefault true;

    # Disko XFS layout
    disko.devices.disk.main = { ... };  # see profile below
    disko.imageBuilder.imageFormat = "qcow2";
  })
];
```

Results:

- `fileSystems."/".fsType` = `"xfs"` (disko owns it, no conflict)
- `fileSystems."/boot".device` = `"/dev/disk/by-partlabel/disk-main-ESP"`
- `system.build.diskoImages` = present (disko image builder)
- `system.build.metadata` = present (Incus metadata from `lxc-instance-common.nix`)
- `system.build.qemuImage` = absent (not pulling in `make-disk-image.nix`)
- All boot config, virtio modules, incus agent = correctly set

## Implementation Plan

### Step 1: Create `modules/incus/disko-virtual-machine.nix`

A drop-in replacement for `incus-virtual-machine.nix` that expects disko to
handle the disk layout:

```nix
# modules/incus/disko-virtual-machine.nix
{ pkgs, lib, ... }:
let
  serialDevice = if pkgs.stdenv.hostPlatform.isx86 then "ttyS0" else "ttyAMA0";
in {
  imports = [
    "${pkgs.path}/nixos/modules/virtualisation/lxc-instance-common.nix"
    "${pkgs.path}/nixos/modules/profiles/qemu-guest.nix"
  ];

  config = {
    boot.growPartition = true;
    boot.loader.systemd-boot.enable = true;
    boot.loader.grub.device = "/dev/vda";
    boot.kernelParams = [ "console=tty1" "console=${serialDevice}" ];

    services.udev.extraRules = ''
      SUBSYSTEM=="cpu", CONST{arch}=="x86-64", TEST=="online", ATTR{online}=="0", ATTR{online}="1"
    '';

    virtualisation.incus.agent.enable = lib.mkDefault true;
  };
}
```

This is intentionally minimal — it provides only the things that
`incus-virtual-machine.nix` provides beyond disk layout (which disko handles).

### Step 2: Create `profiles/disko/incus-vm.nix`

```nix
# profiles/disko/incus-vm.nix
{ disk ? "/dev/vda", ... }: {
  disko.devices.disk.main = {
    type = "disk";
    device = disk;
    imageSize = "10G";  # minimum; incus grows at runtime via limits.disk
    content = {
      type = "gpt";
      partitions = {
        esp = {
          name = "ESP";
          size = "256M";
          type = "EF00";
          content = {
            type = "filesystem";
            format = "vfat";
            mountpoint = "/boot";
            mountOptions = [ "fmask=0077" "dmask=0077" ];
          };
        };
        root = {
          name = "nixos";
          size = "100%";
          content = {
            type = "filesystem";
            format = "xfs";
            mountpoint = "/";
            mountOptions = [ "defaults" "noatime" ];
          };
        };
      };
    };
  };

  disko.imageBuilder.imageFormat = "qcow2";
}
```

Design decisions:

- **No LUKS**: Host disk is already encrypted. No security benefit for VMs.
- **XFS root**: Handles full-disk gracefully — ENOSPC without journal corruption.
- **Small `imageSize` (10G)**: Only needs to hold the initial NixOS closure.
  Incus grows the disk to `limits.disk` at runtime, and `boot.growPartition` +
  `systemd-growfs` expands the partition and filesystem on boot.
- **`/dev/vda`**: Virtio disk device used by Incus/QEMU VMs.

### Step 3: Update `flake.nix` — new builder for disko-based Incus VMs

Add a `mk-incus-vm-disko` builder (or update `mk-incus-vm`) that imports the
new module instead of `incus-virtual-machine.nix`:

```nix
mk-incus-vm-disko = guestModule:
  nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [
      guestModule
      sops-nix.nixosModules.sops
      impermanence.nixosModules.impermanence
      disko.nixosModules.disko
      self.nixosModules.common
      ./modules/incus/disko-virtual-machine.nix
      ./modules/incus/guest-options.nix
      { nixpkgs = { overlays = ...; config.allowUnfree = true; }; }
    ];
  };
```

Key difference from `mk-incus-vm`:

- `disko.nixosModules.disko` replaces the nixpkgs incus-virtual-machine module
- `./modules/incus/disko-virtual-machine.nix` provides the boot/agent config

Existing guests using `mk-incus-vm` continue to work unchanged (ext4). New
guests or migrated guests use `mk-incus-vm-disko` (XFS via disko).

### Step 4: Update `mkVMImage` in `modules/incus/default.nix`

Support disko-based images alongside the existing `qemuImage` path:

```nix
mkVMImage = name: guestCfg: let
  sys = guestCfg.system.config;
in
  pkgs.runCommand "${name}-vm-image" {} ''
    mkdir -p $out
    ln -s ${sys.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
    ${if sys.system.build ? diskoImages then
      "ln -s ${sys.system.build.diskoImages}/*.qcow2 $out/disk.qcow2"
    else
      "ln -s ${sys.system.build.qemuImage}/*.qcow2 $out/disk.qcow2"
    }
  '';
```

If the guest has `system.build.diskoImages` (disko-based), use that. Otherwise
fall back to `system.build.qemuImage` (ext4, existing behavior).

### Step 5: Migrate edith to use disko

Update `hosts/calvard/incus/guests/edith/default.nix` to import the disko
profile:

```nix
{
  imports = [
    ./sops.nix
    (import ../../../../profiles/disko/incus-vm.nix {})
  ];

  # ... rest unchanged ...
}
```

Update `modules/common/incus.nix` (or wherever edith is wired into the flake)
to use `mk-incus-vm-disko` instead of `mk-incus-vm`.

Then tear down and recreate edith:

```bash
incus exec edith -- tar cf - /home > /tmp/edith-home-backup.tar
incus stop edith
incus delete edith
incus image delete edith
nixos-rebuild switch --flake <path>
systemctl start incus-ensure-instances
incus-update-instance edith
cat /tmp/edith-home-backup.tar | incus exec edith -- tar xf - -C /
incus exec edith -- df -Th /   # should show xfs
```

### Step 6: Test

1. **Build the image**: Verify disko produces a qcow2 with XFS root.

2. **Boot and verify**:
   - `df -Th /` shows xfs
   - Correct IP (10.97.21.42)
   - `boot.growPartition` expands disk to `limits.disk` size
   - `switch-to-configuration switch` persists across reboot

3. **Full-disk resilience test**: Fill the disk inside the VM, verify XFS
   returns ENOSPC without journal corruption or read-only remount. Run
   `nix-collect-garbage -d` to recover.

4. **Update the integration test**: Add a disko-based variant to
   `tests/modules/incus-vm.nix`, or create a new test.

### Step 7: Consider retiring `mk-incus-vm`

Once edith is proven on disko, consider migrating all future Incus VMs to
`mk-incus-vm-disko` and eventually dropping `mk-incus-vm`. No rush — edith is
currently the only Incus VM.

## Open Questions

1. **`boot.growPartition` + XFS**: Uses `growpart` (GPT-level) then
   `systemd-growfs` → `xfs_growfs`. Should work but needs testing with disko's
   partlabel naming (`/dev/disk/by-partlabel/disk-main-nixos`).

2. **Disko image output path**: `diskoImages/<imageName>.<format>` where
   `imageName` defaults to the disk name (`main`). The glob `*.qcow2` in
   `mkVMImage` should match, but verify the exact filename.

3. **`disko.memSize`**: Default RAM for the build VM. If the NixOS closure is
   large, the build VM may need more memory. Default is 1024 MiB — probably
   fine for edith but monitor build failures.

## Files to Create/Modify

- `modules/incus/disko-virtual-machine.nix` — **new** — drop-in replacement
- `profiles/disko/incus-vm.nix` — **new** — XFS disko profile for Incus VMs
- `flake.nix` — add `mk-incus-vm-disko` builder
- `modules/incus/default.nix` — update `mkVMImage` for disko support
- `modules/common/incus.nix` — wire edith to `mk-incus-vm-disko`
- `hosts/calvard/incus/guests/edith/default.nix` — import disko profile
- `tests/modules/incus-vm.nix` — add disko-based test variant

## Interim Workaround

Until the disko migration is implemented, the practical mitigation for ext4
Incus VMs:

1. **Increase disk headroom**: Set `limits.disk = "150GB"` or higher for
   development VMs that accumulate nix store bloat
2. **Periodic GC**: Add a systemd timer inside the guest that runs
   `nix-collect-garbage -d` regularly
3. **Image update feature**: Already implemented (marker file in
   `incus-ensure-instances`) — ensures recreated instances use the latest config
4. **If ext4 corrupts again**: Follow the recovery procedure below

### Recovery Procedure (Validated)

If an Incus VM becomes unrecoverable (ext4 journal corruption, wrong IP, etc.),
tear down and recreate from the declarative config. Run on calvard:

```bash
# 1. Backup user data while the VM is still accessible via incus exec
#    (incus exec uses vsock, works even when guest networking is broken)
#    Note: gzip may not be available in the guest — use plain tar
incus exec <name> -- tar cf - /home > /tmp/<name>-home-backup.tar

# 2. Delete the broken instance and stale image
incus stop <name>
incus delete <name>
incus image delete <name>

# 3. Rebuild calvard if the NixOS config has changed since last deploy
#    (skip if already deployed with latest config)
nixos-rebuild switch --flake <flake-path>

# 4. Recreate from the current NixOS config
systemctl start incus-ensure-instances

# 5. Push the latest NixOS closure into the new instance
incus-update-instance <name>

# 6. Restore the backup
cat /tmp/<name>-home-backup.tar | incus exec <name> -- tar xf - -C /

# 7. Verify correct IP and reboot persistence
incus list
incus restart <name>
incus list   # IP should be unchanged after reboot
```

Things that survive instance deletion (no backup needed):

- SSH host keys and sops age keys (host-side `/persist/guests/<name>/static/`)
- The NixOS system config (declarative, in the repo)

Things that are lost (backup if needed):

- User home directories
- Any in-guest state on the root filesystem (databases, logs, etc.)

## References

- Disko image builder docs: https://github.com/nix-community/disko/blob/master/docs/disko-images.md
- Disko image builder source: `<disko>/lib/make-disk-image.nix`
- nixpkgs `incus-virtual-machine.nix`: `<nixpkgs>/nixos/modules/virtualisation/incus-virtual-machine.nix`
- nixpkgs image builder unification issue: https://github.com/NixOS/nixpkgs/issues/324817
- Current incus module: `modules/incus/default.nix`
