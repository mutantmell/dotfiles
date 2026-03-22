# XFS Support for Incus VM Images

## Problem

Incus VM images are built via nixpkgs' `make-disk-image.nix`, which hardcodes
ext4 when a partition table is present. This caused a cascading failure on edith
(Incus VM on calvard): disk filled up → ext4 journal corruption → read-only
filesystem → GC couldn't run → VM unrecoverable, had to tear down and recreate.

XFS handles full-disk scenarios more gracefully (pre-allocated journal, returns
ENOSPC without corruption or forced read-only remount), but
`make-disk-image.nix` can't produce XFS images with partition tables.

## Investigation Summary

We explored two alternative approaches before concluding that an upstream fix is
the right answer:

### Approach 1: Disko Image Builder (Rejected — too much overhead)

Disko has its own `system.build.diskoImages` that runs disko inside a QEMU VM
during the Nix build, supporting arbitrary filesystems. This works (validated
with eval tests) but requires:
- A new disko profile for Incus VMs
- Replacing or cherry-picking from `incus-virtual-machine.nix` (it conflicts
  with disko's fileSystems definitions — confirmed via eval test)
- Wiring `system.build.diskoImages` into the incus-manager module
- Slower builds (full VM boot vs LKL tooling)

This is a lot of machinery for what is fundamentally a one-line limitation in
`make-disk-image.nix`.

### Approach 2: guestfish (Rejected — custom image pipeline)

Follow microvm.nix's pattern using `parted` + `guestfish` to build images.
`guestfish mkfs xfs` supports XFS natively. But this means maintaining a custom
image builder — essentially writing a second `make-disk-image.nix`.

### Approach 3: Upstream PR to `make-disk-image.nix` (Recommended)

Fix the root cause in nixpkgs. The ext4 hardcoding exists for two specific
reasons, both solvable:

1. **`mkfs` and `cptofs` use ext4-specific flags** — need filesystem-aware
   formatting and copying
2. **An assertion blocks non-ext4 with partition tables** — needs to be relaxed

This is the least overhead, benefits the entire NixOS community, and keeps our
Incus module unchanged.

## What Needs to Change in `make-disk-image.nix`

The file is at `<nixpkgs>/nixos/lib/make-disk-image.nix`. All line references
are to the current version (nixpkgs 25.05).

### Change 1: Remove the ext4 assertion (line 222)

```nix
# CURRENT (line 222):
assert (
  lib.assertMsg (partitionTableType != "none" -> fsType == "ext4")
    "to produce a partition table, we need to use -E offset flag which is support only for fsType = ext4"
);

# PROPOSED: allow ext4 and xfs
assert (
  lib.assertMsg (partitionTableType != "none" -> lib.elem fsType ["ext4" "xfs"])
    "partitioned disk images currently support fsType ext4 or xfs"
);
```

### Change 2: Make `mkfs` invocation filesystem-aware (lines 613-625)

The current code uses ext4-specific flags (`-b`, `-F`, `-E offset=`):

```bash
# CURRENT (line 619):
mkfs.${fsType} -b ${blockSize} -F -L ${label} $diskImage -E offset=$(sectorsToBytes $START) $(sectorsToKilobytes $SECTORS)K
```

XFS's `mkfs.xfs` has completely different flags. The fix is to branch:

```bash
# PROPOSED:
if partitionTableType != "none" then
  if fsType == "ext4" then
    # ext4: format with -E offset (LKL in-place formatting without loopback)
    mkfs.ext4 -b ${blockSize} -F -L ${label} $diskImage -E offset=$(sectorsToBytes $START) $(sectorsToKilobytes $SECTORS)K
  else
    # Other filesystems: extract partition to loopback device and format
    LOOP=$(losetup --find --show --offset $(sectorsToBytes $START) --sizelimit $(sectorsToBytes $SECTORS) $diskImage)
    mkfs.${fsType} -L ${label} $LOOP
    losetup -d $LOOP
```

**Key insight**: ext4's `mkfs -E offset=` is a special feature that formats a
partition directly inside a raw disk image without needing a loopback device.
Other filesystems don't have this — they need `losetup` to expose the partition
as a block device first.

However, `losetup` requires root or `/dev/loop*` access, which isn't available
in a normal Nix sandbox. This code runs inside `vmTools.runInLinuxVM` (the
in-VM phase at line 660), where loopback IS available. But the `mkfs` call at
line 619 happens in `prepareImage` (the pre-VM phase, line 428), which runs in
the Nix sandbox.

**This is the core technical challenge**: ext4's `-E offset` trick lets
`make-disk-image.nix` format the partition without a VM. For XFS, the formatting
would need to move into the VM phase (after line 700 where the disk is already
available as `/dev/vda`).

### Change 3: Replace `cptofs` for non-ext4 (lines 627-632)

```bash
# CURRENT:
cptofs -p -P ${rootPartition} -t ${fsType} -i $diskImage $root/* /
```

`cptofs` is an LKL tool that only supports ext4. For XFS, the copy needs to
happen inside the VM (where the filesystem is mounted at `/mnt`). The flow
becomes:

- **ext4 path** (unchanged): `cptofs` in the pre-VM sandbox phase
- **XFS path**: skip `cptofs` in pre-VM, instead copy files via
  `nixos-install` in the VM phase (this already happens at line 519, but
  currently runs in the pre-VM sandbox)

This means for XFS, both `mkfs` and the file copy need to move from the pre-VM
`prepareImage` phase into the in-VM `buildImage` phase. The VM phase already
mounts the disk, installs the bootloader, etc. — it just needs to also handle
formatting and populating the root filesystem for non-ext4.

### Change 4: Filesystem-aware size calculation (lines 426, 451-456)

```nix
# CURRENT:
blockSize = toString (4 * 1024); # ext4fs block size
compute_fudge() {  # ext4 reserved space percentage
  echo $(( $1 * 52 / 1000 ))
}
```

XFS has different overhead characteristics. The fudge factor and block size
should be conditional:

```nix
blockSize = toString (if fsType == "xfs" then 4096 else 4096);  # same default, but explicit
# XFS doesn't reserve 5% by default like ext4, so fudge can be smaller
```

In practice, XFS's overhead is lower than ext4's. A simpler approach: keep the
ext4 fudge for XFS too (slightly oversizes the image, which is fine).

### Change 5: Add `xfsprogs` to build inputs (line 392-407)

```nix
binPath = lib.makeBinPath (with pkgs; [
  rsync util-linux parted e2fsprogs lkl ...
  # ADD:
] ++ lib.optional (fsType == "xfs") xfsprogs
```

And in the VM phase build inputs (line 664):

```nix
buildInputs = with pkgs; [
  util-linux e2fsprogs dosfstools
  # ADD:
] ++ lib.optional (fsType == "xfs") xfsprogs;
```

### Change 6: Skip ext4-specific tune2fs in VM phase (line 692-694)

```nix
# CURRENT:
${lib.optionalString (fsType == "ext4" && deterministic) ''
  tune2fs -T now -U ${rootFSUID} -c 0 -i 0 $rootDisk
''}
```

This is already guarded by `fsType == "ext4"`, so no change needed. But the
`deterministic` option's assertion (line 217) also needs updating:

```nix
# CURRENT:
lib.assertMsg (fsType == "ext4" && deterministic -> rootFSUID != null) ...

# Fine as-is — only applies when fsType == "ext4"
```

### Change 7: Update `incus-virtual-machine.nix` (optional)

Once `make-disk-image.nix` supports XFS, `incus-virtual-machine.nix` could
accept a configurable fsType:

```nix
# CURRENT:
fileSystems."/" = {
  device = "/dev/disk/by-label/nixos";
  autoResize = true;
  fsType = "ext4";
};

# PROPOSED:
fileSystems."/" = {
  device = "/dev/disk/by-label/nixos";
  autoResize = true;
  fsType = config.virtualisation.incus.vm.fsType;  # default "ext4"
};
```

This could be a follow-up PR or part of the same one.

## Restructured Approach for the PR

The cleanest path for the PR, given the pre-VM vs in-VM constraint:

### Option A: Move formatting into the VM for all filesystems

Simplify `make-disk-image.nix` by always formatting inside the VM. This removes
the LKL `cptofs` dependency entirely and makes any filesystem work. The tradeoff
is that ext4 images would build slightly slower (need a VM boot). This aligns
with the comment at the top of the file:

> please consider to work towards the effort of unifying our image builders,
> as outlined in https://github.com/NixOS/nixpkgs/issues/324817

### Option B: Keep ext4 fast path, add VM-based path for others

Less disruptive. ext4 keeps using `cptofs` + `-E offset` (no VM needed for
formatting). XFS and future filesystems use the VM path. The downside is two
code paths to maintain.

**Option B is probably more acceptable upstream** — it doesn't regress ext4
build performance and is a smaller diff.

## Implementation Sketch (Option B)

The key change is splitting `prepareImage` into two parts:

1. **Common pre-VM work** (runs in sandbox): partition the disk, copy closure
   to staging root, run `nixos-install` in staging
2. **ext4 pre-VM work** (runs in sandbox): `mkfs.ext4 -E offset=...` + `cptofs`
3. **Non-ext4 VM work** (runs in VM): `mkfs.xfs` on `/dev/vdaN` + copy from
   staging root (passed via 9p/virtiofs share)

The VM phase already has the disk as `/dev/vda` and mounts it. For XFS, instead
of `cptofs` pre-populating the image, the VM phase would:

```bash
# Format the root partition
mkfs.xfs -L nixos /dev/vda${rootPartition}
mount /dev/vda${rootPartition} /mnt

# Copy the staging root (passed in via 9p share)
cp -a /tmp/xchg/root/* /mnt/

# Install bootloader (already happens)
nixos-install --root /mnt ...
```

The staging root can be passed to the VM via the existing `xchg` mechanism that
`vmTools.runInLinuxVM` provides.

## Testing the PR

The PR should include a NixOS VM test that:

1. Builds an XFS disk image via `make-disk-image.nix`
2. Boots it in a VM
3. Verifies `mount` shows XFS on `/`
4. Verifies `systemd-growfs` works (disk auto-resize)
5. Fills the disk to near-capacity and verifies graceful ENOSPC (no journal
   corruption, no read-only remount)

Existing tests to reference:
- `nixos/tests/image/make-disk-image.nix` (if it exists)
- `nixos/tests/incus/` tests

## References

- `make-disk-image.nix`: `<nixpkgs>/nixos/lib/make-disk-image.nix`
- `incus-virtual-machine.nix`: `<nixpkgs>/nixos/modules/virtualisation/incus-virtual-machine.nix`
- Image builder unification issue: https://github.com/NixOS/nixpkgs/issues/324817
- LKL project (provides `cptofs`): https://github.com/lkl/linux
- `cptofs` ext4 limitation: LKL only implements ext4 filesystem operations

## Interim Workaround

Until the upstream PR lands, the practical mitigation for our Incus VMs:

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

## Disko Fallback (If Upstream PR Is Not Accepted)

If the upstream maintainers don't want to expand `make-disk-image.nix`'s
filesystem support (e.g., they prefer the disko path per issue #324817), the
disko-based approach is fully validated:

- Disko's `system.build.diskoImages` produces qcow2 with XFS — confirmed
- `incus-virtual-machine.nix` conflict resolved by cherry-picking its
  non-filesystem parts (incus agent, qemu guest profile, kernel params, CPU
  hotplug) into a local `modules/incus/disko-virtual-machine.nix` — confirmed
  via eval test
- `system.build.metadata` (Incus metadata tarball) still generates correctly
  when importing `lxc-instance-common.nix` directly — confirmed via eval test
