# Disko-based Incus VM Image Builder

## Problem

Incus VM images are currently built via nixpkgs' `make-disk-image.nix`, which
hardcodes ext4 when a partition table is present. This caused a cascading failure:
disk filled up → ext4 journal corruption → read-only filesystem → GC couldn't
run → VM unrecoverable. XFS handles full-disk scenarios more gracefully
(pre-allocated journal, no corruption cascade), but `make-disk-image.nix` can't
produce XFS images.

## Solution

Replace `make-disk-image.nix` with disko's `system.build.diskoImages` for Incus
VM image building. Disko has its own image builder that runs inside a QEMU VM
during the Nix build, supports arbitrary filesystems (XFS, btrfs, ZFS), and
outputs qcow2 images.

## How disko's Image Builder Works

Disko's `make-disk-image.nix` (at `lib/make-disk-image.nix` in the disko flake):

1. **Pre-VM**: Creates empty qcow2 disk images sized per `disko.devices.disk.*.imageSize`
2. **In-VM**: Boots a QEMU VM with OVMF (UEFI), runs disko's
   `destroyFormatMount` to partition and format disks, then runs `nixos-install`
   to populate the filesystem from the NixOS closure
3. **Post-VM**: Outputs the qcow2 images

Key options:
- `disko.imageBuilder.imageFormat` — `"raw"` (default) or `"qcow2"`
- `disko.imageBuilder.copyNixStore` — whether to populate the nix store (default `true`)
- `disko.imageBuilder.extraPostVM` — post-processing (e.g. compression)
- `disko.imageBuilder.extraConfig` — extra NixOS config for the build VM
  (useful for dummy LUKS keys)
- `disko.memSize` — RAM for the build VM (in MiB)
- `disko.devices.disk.*.imageSize` — size of each disk image
- `disko.devices.disk.*.imageName` — filename for each disk image

Output: `system.build.diskoImages` — a derivation containing the disk images.

## Critical Blocker: `incus-virtual-machine.nix` Conflict

The `incus-virtual-machine.nix` module from nixpkgs hardcodes ext4 `fileSystems`
entries for `/` and `/boot`, and produces `system.build.qemuImage` via nixpkgs'
`make-disk-image.nix`. Disko needs to replace both the filesystem definitions
and the image builder. **Resolving this conflict is the first thing to
investigate** — if `mkForce` on disko's fileSystems is sufficient, the rest of
the plan is straightforward. If not, we may need to stop importing
`incus-virtual-machine.nix` entirely and instead cherry-pick just the parts we
need (incus agent, qemu guest profile, kernel params, CPU hotplug udev rule).

## Implementation Plan

### Step 1: Create a disko profile for Incus VMs

Create `profiles/disko/incus-vm.nix` — a simple XFS layout without LUKS
(encryption is unnecessary for VMs running on an already-encrypted host).

```nix
# profiles/disko/incus-vm.nix
{ disk ? "/dev/vda", ... }: {
  disko.devices = {
    disk.main = {
      type = "disk";
      device = disk;
      imageSize = "10G";  # minimum image size; incus grows at runtime
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
  };
}
```

Design decisions:
- **No LUKS**: The host disk is already encrypted. Adding LUKS to a VM image
  complicates the build (needs a dummy key for image creation) and adds overhead
  with no security benefit.
- **XFS root**: Handles full-disk gracefully — returns ENOSPC without journal
  corruption or forced read-only remount.
- **Small `imageSize`**: The image only needs to hold the initial NixOS closure.
  Incus grows the disk to `limits.disk` at runtime, and NixOS's
  `boot.growPartition = true` + XFS's `autoResize = true` expand it on boot.
- **`/dev/vda`**: The virtio disk device name used by Incus/QEMU VMs.

### Step 2: Add disko to the edith guest config

Modify `hosts/calvard/incus/guests/edith/default.nix`:

```nix
{
  imports = [
    ./sops.nix
    (import ../../../../profiles/disko/incus-vm.nix { })
  ];

  disko.imageBuilder.imageFormat = "qcow2";

  # Remove the fileSystems config from incus-virtual-machine.nix
  # since disko now manages the partition layout
  fileSystems = lib.mkForce { };  # disko provides these

  # ... rest of edith's config unchanged ...
}
```

**Open question**: `incus-virtual-machine.nix` sets `fileSystems."/"` and
`fileSystems."/boot"` with hardcoded ext4/vfat. We need to override or disable
those. Options:
- `lib.mkForce` on the disko-provided fileSystems
- Don't import `incus-virtual-machine.nix` at all; instead import only the parts
  we need (incus agent, qemu guest profile, kernel params)
- Use disko's `disko.testMode` which may handle this

This needs investigation. The `incus-virtual-machine.nix` module provides:
- `system.build.qemuImage` (replaced by `system.build.diskoImages`)
- `fileSystems` for `/` and `/boot` (replaced by disko)
- `boot.growPartition = true` (still needed)
- `boot.loader.systemd-boot.enable = true` (still needed)
- `boot.loader.grub.device = "/dev/vda"` (still needed for image builder)
- `boot.kernelParams` for serial console (still needed)
- CPU hotplug udev rule (still needed)
- `virtualisation.incus.agent.enable` (still needed)

We may want to keep importing `incus-virtual-machine.nix` and just `mkForce`
the fileSystems, or extract the non-filesystem parts into a separate module.

### Step 3: Update mkVMImage in the incus module

Modify `modules/incus/default.nix` to support disko-based images:

```nix
mkVMImage = name: guestCfg: let
  sys = guestCfg.system.config;
  useDisko = sys ? disko && sys.disko.devices != {};
in
  if useDisko then
    # disko produces images at system.build.diskoImages/<imageName>.<format>
    pkgs.runCommand "${name}-vm-image" {} ''
      mkdir -p $out
      ln -s ${sys.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
      ln -s ${sys.system.build.diskoImages}/*.qcow2 $out/disk.qcow2
    ''
  else
    # Fallback to nixpkgs' make-disk-image.nix (ext4)
    pkgs.runCommand "${name}-vm-image" {} ''
      mkdir -p $out
      ln -s ${sys.system.build.metadata}/tarball/*.tar.xz $out/metadata.tar.xz
      ln -s ${sys.system.build.qemuImage}/*.qcow2 $out/disk.qcow2
    '';
```

The fallback preserves compatibility — guests without disko continue to use the
existing ext4 image path.

**Note**: The disko image output path is
`diskoImages/<imageName>.<imageFormat>` where `imageName` defaults to the disk
name (e.g., `main`). So the glob `*.qcow2` should work, but verify the exact
filename.

### Step 4: Handle the metadata tarball

`system.build.metadata` comes from `incus-virtual-machine.nix` via
`lxc-instance-common.nix`. This should still work since we're keeping that
module imported. Verify that disko doesn't interfere with the metadata
generation.

### Step 5: Test

1. **Build the image**: `nix build .#incusGuests.edith.system.config.system.build.diskoImages`
   (or however the guest system is exposed). Verify it produces a qcow2 with XFS.

2. **Inspect the image**:
   ```bash
   qemu-img info result/*.qcow2
   # Mount and check filesystem type
   losetup -fP result/*.qcow2
   lsblk /dev/loop0
   file -s /dev/loop0p2  # should show XFS
   ```

3. **Import and boot in Incus**: Delete the old edith, import the new image,
   create and start the instance. Verify:
   - Boots with correct XFS root
   - Network config is correct
   - `boot.growPartition` expands to the full disk size
   - `switch-to-configuration switch` works and persists across reboot

4. **Full-disk test**: Fill the disk inside the VM, verify XFS handles it
   gracefully (ENOSPC errors but no journal corruption, no read-only remount).

5. **Update the integration test**: Modify `tests/modules/incus-vm.nix` to test
   with a disko-based image, or add a new test.

### Step 6: Consider for other guests

Once proven on edith, this can be adopted for any future Incus VM guests. The
disko profile is reusable — guests just import it and set their
`disko.imageBuilder.imageFormat = "qcow2"`.

## Risks and Open Questions

1. **`incus-virtual-machine.nix` conflict**: The biggest unknown. The module
   hardcodes `fileSystems` entries that conflict with disko. Need to test whether
   `mkForce` on disko's fileSystems is sufficient, or if we need to split the
   module apart.

2. **`boot.growPartition`**: Currently uses `cloud-utils` which calls
   `growpart` (designed for ext4/common partition types). Verify it works with
   XFS partitions. XFS has its own `xfs_growfs` for filesystem expansion, but
   the partition itself needs to grow first (GPT-level), then the filesystem.
   NixOS's `autoResize = true` on the fileSystems entry should handle the
   filesystem resize via `systemd-growfs`.

3. **Image size**: disko's `imageSize` sets the initial qcow2 size. It needs to
   be large enough to hold the NixOS closure but small enough that the build
   doesn't take forever. 10GB should be sufficient for the initial install; Incus
   grows it to `limits.disk` at runtime.

4. **Build time**: disko's image builder runs a full QEMU VM during the Nix
   build. This is slower than `make-disk-image.nix`'s LKL approach. Acceptable
   for a one-time image build, but worth noting.

5. **metadata compatibility**: Verify that `system.build.metadata` (Incus
   metadata tarball) is still generated correctly when disko is involved. This
   comes from `lxc-instance-common.nix`, which shouldn't be affected by disko,
   but needs confirmation.

6. **Disk device naming**: Incus VMs use virtio (`/dev/vda`). The disko profile
   must use `/dev/vda`, not `/dev/sda`. The `incus-virtual-machine.nix` module's
   `boot.loader.grub.device = "/dev/vda"` should still apply.

## Files to Modify

- `profiles/disko/incus-vm.nix` — **new** — XFS disko profile for Incus VMs
- `hosts/calvard/incus/guests/edith/default.nix` — add disko import + config
- `modules/incus/default.nix` — update `mkVMImage` to support disko output
- `flake.nix` — possibly update `mk-incus-vm` to include disko module
- `tests/modules/incus-vm.nix` — update or add test for disko-based images

## References

- Disko image builder source: `<disko>/lib/make-disk-image.nix`
- Disko image builder options: `<disko>/module.nix` (lines 23-137)
- nixpkgs `incus-virtual-machine.nix`: `<nixpkgs>/nixos/modules/virtualisation/incus-virtual-machine.nix`
- microvm.nix boot-disk builder (inspiration for alternative approaches):
  `<microvm>/nixos-modules/microvm/boot-disk.nix`
- Current incus module: `modules/incus/default.nix`
