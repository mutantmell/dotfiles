# Media Organization Pipeline - Implementation Plan

## Context

The spec at `llm-notes/specs/jellyfin-media-organization.md` defines a media pipeline architecture with least-privilege NFS separation: write-access services (arr stack) on the NAS, read-only serving (Jellyfin) on a separate node. This maps cleanly to the existing infrastructure:

| Spec Role               | Host                        | Status                               |
| ----------------------- | --------------------------- | ------------------------------------ |
| NAS (arr stack, NFS)    | **liberl** (née remiferia)  | Needs disko reformat + new arr guest |
| Serving node (Jellyfin) | **calvard** (oracion guest) | Partially done, needs fixes          |
| Encoding node (Unmanic) | **erebonia**                | Future work (out of scope)           |

The core deliverable is: liberl (formerly remiferia) reformatted with btrfs/impermanence, a new arr stack microvm, hardened NFS exports, and Jellyfin configuration fixes on calvard.

---

## Phase 1: Rename + Disko Reformat

**Goal:** Rename remiferia → liberl (and guests to Liberl-region names from Trails in the Sky), replace ext4 root with btrfs + impermanence + L2ARC partition, preserving the ZFS `data` pool.

### 1.0 Rename remiferia → liberl

Since we're reformatting from scratch (new SSH keys, new sops age keys, fresh guest state), this is the ideal time to rename. The rename is mechanical find-and-replace across the codebase.

**Name mapping:**

| Old Name      | New Name    | Role                                                                |
| ------------- | ----------- | ------------------------------------------------------------------- |
| remiferia     | **liberl**  | NAS host                                                            |
| ardent        | **zeiss**   | Attic binary cache                                                  |
| monrain       | _(removed)_ | cgit git hosting — eliminated; all git repos are on creil (Forgejo) |
| _(new)_ denai | **bose**    | Arr stack (Sonarr, Radarr, Bazarr)                                  |

**Codebase changes:**

1. **Directory renames:**
   - `hosts/remiferia/` → `hosts/liberl/`
   - `hosts/liberl/microvm/guests/ardent/` → `hosts/liberl/microvm/guests/zeiss/`
   - `hosts/liberl/microvm/guests/monrain/` → _(removed; see note below)_

2. **Network registry** (`lib/common/data/network.nix`):
   - Rename `remiferia = 20` → `liberl = 20` in management zone
   - Rename `ardent = 31` → `zeiss = 31` in dmz zone
   - Remove `monrain = 32` from dmz zone entirely (guest eliminated)
   - New arr guest: `bose = XX` in lab zone (instead of `denai`)

3. **DNS aliases for transition** (`lib/common/data/network.nix` `hostAliases`):

   ```nix
   hostAliases = {
     # ... existing aliases ...
     liberl = [
       "remiferia.internal.mutantmell.net"
       "remiferia.internal"
     ];
     zeiss = [
       "ardent.internal.mutantmell.net"
       "ardent.internal"
       "attic.ardent.internal.mutantmell.net"
       "attic.ardent.internal"
     ];
   };
   ```

   > **Note:** No transition alias was added for ruan/monrain — ruan was eliminated entirely.

   These keep old DNS names working during the transition. Remove once all references are updated.

4. **Host config** (`hosts/liberl/default.nix`):
   - `networking.hostName = "liberl"`
   - Generate new `networking.hostId` (required for ZFS — `head -c 8 /dev/urandom | od -A none -t x4 | tr -d ' '`)

5. **NAS config** (`hosts/liberl/nas.nix`):
   - Samba: `"server string" = "LIBERL"`, `"netbios name" = "LIBERL"`

6. **NFS consumers** — update device paths:
   - `hosts/calvard/default.nix` — `remiferia.internal` → `liberl.internal`
   - `hosts/erebonia/default.nix` — `remiferia.internal` → `liberl.internal`
     (DNS aliases mean the old names still resolve, but update for correctness)

7. **Monitoring** (`hosts/calvard/microvm/guests/tharbad/`):
   - Prometheus scrape targets: rename remiferia → liberl, ardent → zeiss; remove monrain/ruan
   - Loki config: update host references
   - `default.nix` extraHosts: rename entries

8. **Guest internals** — update `networking.hostName`, tap interface names, MAC addresses:
   - zeiss: `vm-100-zeiss`, update MAC

9. **Sops secrets** — host key paths change with new hostnames. Since we're regenerating all keys on reformat, just ensure `sops.nix` files reference the correct new paths.

10. **flake.nix** — `nixosConfigurations.remiferia` → `nixosConfigurations.liberl`

11. **docs/hostnames.md** — Move liberl from GP host to NAS host, update guest assignments, remove remiferia entry.

12. **Grep sweep** — `grep -r remiferia`, `grep -r ardent`, `grep -r monrain` across the repo to catch any remaining references (plans, comments, etc.).

### 1.1 Extend the existing btrfs disko profile

Add an optional `l2arcSize` parameter to `profiles/disko/btrfs.nix`. When set, disko creates a third partition (raw, no filesystem) between the ESP and the LUKS partition, sized for use as a ZFS L2ARC cache device. When unset (default), behavior is unchanged — erebonia and calvard are unaffected.

**File: `profiles/disko/btrfs.nix`**

Current signature: `{disk ? "/dev/sda", ...}`
New signature: `{disk ? "/dev/sda", l2arcSize ? null, ...}`

When `l2arcSize` is non-null (e.g. `"32G"`), add a raw partition with no `content` block:

```nix
l2arc = {
  name = "l2arc";
  size = l2arcSize;  # e.g. "32G"
  # No content — ZFS manages this partition via `zpool add data cache`
};
```

The L2ARC keeps frequently-accessed ZFS metadata and small files warm on the SSD, allowing HDD spindown between actual media operations (spec line 369). This must be done at initial partitioning time to avoid repartitioning later.

**Note:** The actual `zpool add data cache /dev/sdXN` is a one-time manual step after first boot (see deployment checklist). Disko just creates the partition.

### 1.2 Update liberl host config

**Files to modify:**

- `hosts/liberl/default.nix` — Replace `hardware-configuration.nix` filesystem declarations with disko profile import, enable impermanence + btrfs modules
- `hosts/liberl/hardware-configuration.nix` — Strip filesystem declarations (keep kernel modules, CPU microcode, `nixpkgs.hostPlatform`, initrd modules)
- `flake.nix` — Add `disko.nixosModules.disko` to liberl's module list

**New config pattern (matching erebonia/calvard):**

```nix
imports = [
  ./hardware-configuration.nix  # kernel modules, CPU microcode (stripped of FS decls)
  (import ../../profiles/disko/btrfs.nix { disk = "/dev/sdX"; l2arcSize = "32G"; }) # verify device + size
  ./impermanence.nix
  ./microvm
  ./nas.nix
  ./monit.nix
  ./sops.nix
];

common.impermanence.enable = true;
common.btrfs.enable = true;
common.btrfs.keyfileUnlock.enable = true;
common.btrfs.impermanence.enable = true;
```

### 1.3 Impermanence persistence declarations

**New file: `hosts/liberl/impermanence.nix`**

Standard persisted paths (matching other hosts):

- `/var/log`, `/var/lib/nixos`, `/var/lib/systemd/coredump`

NAS-specific:

- `/var/lib/samba` (Samba state/databases)

ZFS pool auto-imports via `boot.zfs.extraPools = ["data"]` (already in `default.nix`, unchanged). `networking.hostId` will need a new value generated for liberl.

### 1.4 Update microvm guest paths

Currently zeiss (née ardent) uses `/data/guests/{name}/` for static shares and disk images. After disko reformat, these should move to `/persist/guests/{name}/` (on btrfs SSD) to match the convention and keep VM boot off the HDDs. ruan (née monrain) was eliminated entirely.

**Files:**

- `hosts/liberl/microvm/guests/zeiss/microvm.nix` — Update paths `/data/guests/` → `/persist/guests/`

### 1.5 Deployment checklist (manual, not code changes)

Guest disk images and state do not need to be preserved — they will be recreated on first boot.

**Important:** Use a stable device path (`/dev/disk/by-id/...`) for the `disk` parameter in the disko profile, not `/dev/sdX` which can shift between boots.

#### Pre-install: restructure ZFS datasets (run on live remiferia/liberl before reformatting)

Currently the pool has a single `data` dataset with everything as plain directories. Create proper child datasets for independent snapshot/compression/tuning policies. The `data/media` dataset must remain a single dataset (no children) for hardlink support.

- [ ] Verify current layout:

  ```bash
  zfs list -r -o name,mountpoint data
  ```

  Expected: only `data` at `/data`. If child datasets already exist, adapt the steps below accordingly.

- [ ] Move existing data out of the way (temporary directories on pool root):

  ```bash
  # Move current contents to temporary locations so dataset mount points don't conflict
  mv /data/media /data/_media_tmp
  mv /data/backup /data/_backup_tmp
  mv /data/drive /data/_drive_tmp
  # Move anything else that will become a dataset
  ```

- [ ] Create child datasets with appropriate settings:

  ```bash
  # Media: large recordsize for video files, compression off (already-compressed media)
  zfs create -o mountpoint=/data/media -o recordsize=1M -o compression=off data/media

  # Backup: default recordsize, zstd compression
  zfs create -o mountpoint=/data/backup -o compression=zstd data/backup

  # General storage: default recordsize, zstd compression
  zfs create -o mountpoint=/data/general -o compression=zstd data/general

  # Drive (SMB share): default recordsize, zstd compression
  zfs create -o mountpoint=/data/drive -o compression=zstd data/drive
  ```

- [ ] Move data into the new datasets:

  ```bash
  # Use rsync to preserve permissions, ownership, and hardlinks
  rsync -aHAX --remove-source-files /data/_media_tmp/ /data/media/
  rsync -aHAX --remove-source-files /data/_backup_tmp/ /data/backup/
  rsync -aHAX --remove-source-files /data/_drive_tmp/ /data/drive/
  # Clean up empty temp directories
  find /data/_media_tmp /data/_backup_tmp /data/_drive_tmp -type d -empty -delete
  ```

- [ ] Verify the result:

  ```bash
  zfs list -r -o name,mountpoint,recordsize,compression data
  ```

  Expected:

  ```
  NAME          MOUNTPOINT     RECSIZE  COMPRESS
  data          /data          128K     off
  data/backup   /data/backup   128K     zstd
  data/drive    /data/drive    128K     zstd
  data/general  /data/general  128K     zstd
  data/media    /data/media    1M       off
  ```

- [ ] Verify `data/media` has no child datasets (hardlink requirement):
  ```bash
  zfs list -r data/media
  ```
  Must show only one row.

**Note:** Existing hardlinks within `/data/media` will be broken by the `rsync` move (they become separate files on the new dataset). This is acceptable — the arr stack will create new hardlinks going forward. If preserving existing hardlinks matters, use `mv` within the same dataset instead, but since we're moving across dataset boundaries that's not possible here.

#### Pre-install: identify and verify disks

- [ ] Boot from NixOS installer USB
- [ ] Run `lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT,MODEL` to identify all disks
- [ ] Identify the boot SSD (currently has ext4 root + vfat boot) — note its `/dev/disk/by-id/` path:
  ```bash
  ls -la /dev/disk/by-id/ | grep -v part
  ```
- [ ] Confirm which disks belong to the ZFS pool (will show `zfs_member` in FSTYPE)
- [ ] Verify the `disk` parameter in the disko profile points to the correct boot SSD

#### Detach ZFS pool

- [ ] `zpool export data`
- [ ] `zpool status` — should report no pools imported
- [ ] Confirm ZFS disks still visible in `lsblk` but no longer mounted

#### Preview disko (dry run)

- [ ] Run disko dry-run to preview all operations:
  ```bash
  nix run github:nix-community/disko -- --mode disko --dry-run <path-to-config>
  ```
- [ ] **Verify the output only references the boot SSD** — no ZFS disk device paths should appear
- [ ] Review the partition layout: ESP + L2ARC + LUKS/btrfs

#### Run disko and install

- [ ] Run disko for real:
  ```bash
  nix run github:nix-community/disko -- --mode disko <path-to-config>
  ```
- [ ] Install NixOS with the new configuration
- [ ] Reboot into the new system

#### Post-install: restore ZFS and bootstrap guests

- [ ] Verify btrfs root is mounted and impermanence is working (`findmnt /`, `findmnt /persist`)
- [ ] Confirm ZFS pool auto-imported: `zpool status data`
  - If not: `zpool import data`
- [ ] Add L2ARC cache: `zpool add data cache /dev/disk/by-id/<ssd-l2arc-partition>`
- [ ] Verify L2ARC attached: `zpool status data` — should show cache device
- [ ] Run `setup-guest.sh` to bootstrap guest SSH keys + sops age keys into `/persist/guests/`
- [ ] Verify all services come up: NFS exports, SMB, microvm guests (zeiss, bose)

### 1.6 Add disko check

Update the `disko-btrfs` check in `tests/default.nix` to also test the `l2arcSize` parameter variant, or add a second check `disko-btrfs-l2arc`.

---

## Phase 2: NFS Export Hardening

**Goal:** Implement the spec's RO/RW separation with per-host access and UID squashing.

### 2.1 Create media directory structure

On liberl host (one-time manual setup on the ZFS pool):

```
/data/media/
├── torrents/{movies,tv,music}/
├── usenet/complete/{movies,tv,music}/
├── manual/{movies,tv,music}/
└── library/{movies,tv,music}/
```

### 2.2 Update NFS exports and bind mounts

**File: `hosts/liberl/nas.nix`**

Both bind mounts point to the same root for symmetry — the access level (RW vs RO) is the only difference:

- `/export/rw/media` binds to `/data/media` (unchanged)
- `/export/ro/media` binds to `/data/media` (unchanged — **currently already correct**)

Remove unused exports and bind mounts:

- Remove `/export/rw/data`, `/export/ro/data`, `/export/rw/backup` bind mounts
- Remove `/data/data`, `/data/media` direct exports (replaced by `/export/` tree)

New export config using per-host access and UID squashing:

```nix
services.nfs.server.exports = ''
  /export/rw/media  erebonia-ip(rw,sync,no_subtree_check,all_squash,anonuid=${uid},anongid=${gid})
  /export/ro/media  calvard-ip(ro,sync,no_subtree_check,all_squash,anonuid=${uid},anongid=${gid})
'';
```

Where `uid`/`gid` are interpolated from `pkgs.mmell.lib.data.users.media` (UID/GID 400 — allocated in the centralized static registry at `lib/common/data/default.nix`). The spec used `1500` as an illustrative placeholder; the actual value comes from the registry to prevent cross-host collisions.

Key changes from current config:

- **Replace `no_root_squash` with `all_squash,anonuid=<registry-uid>,anongid=<registry-gid>`** — eliminates UID mismatches; UID/GID sourced from centralized registry (400)
- **Per-host access instead of subnet-wide** — only specific hosts that need access
- **RO enforced server-side** — calvard can see staging dirs but cannot write to them
- **Remove unused non-media exports** (`/data/data`, `/export/rw/backup`, etc.)

**SMB shares are left functionally unchanged** — replacing them requires a broader change to the upload workflow. The `drive` share path stays at `/data/drive`. Update the `backup` share path from `/export/rw/backup` to `/data/backup` (direct dataset mount, since the export tree bind mount is being removed).

### 2.3 Create media user/group

**File: `hosts/liberl/nas.nix`** (and arr guest config)

The `media` user/group is allocated at UID/GID 400 in the centralized static registry (`lib/common/data/default.nix`). Reference it via `pkgs.mmell.lib.data.users.media` rather than hardcoding:

```nix
inherit (pkgs.mmell.lib.data.users) media;

users.groups.media.gid = media.gid;  # 400
users.users.media = { inherit (media) uid; group = "media"; isSystemUser = true; };
```

Ensure `/data/media` ownership is `media:media` (400:400) — one-time manual `chown -R 400:400 /data/media`.

### 2.4 Update firewall rules

Update NFS firewall in `nas.nix` to match the new per-host export pattern. Replace subnet-wide rules with specific host IPs (calvard for RO, erebonia for RW).

---

## Phase 3: Arr Stack Microvm (bose)

**Goal:** New microvm on liberl running Sonarr, Radarr, Bazarr with virtiofs access to `/data/media`.

### 3.1 Network setup

**Add VLAN 21 (lab) to liberl networking:**

**File: `hosts/liberl/default.nix`** — Add:

- `enp4s0.21` VLAN netdev
- `br21` bridge
- Network matching `vm-21-*` tap interfaces to `br21`

**File: `lib/common/data/network.nix`** — Add host entry:

```nix
lab = {
  vlanId = 21;
  hosts = {
    edith = 42;
    bose = XX;  # pick next available ID
  };
};
```

### 3.2 Create guest directory structure

```
hosts/liberl/microvm/guests/bose/
├── default.nix     # Main config: networking, egress filtering, impermanence
├── microvm.nix     # cloud-hypervisor, virtiofs shares, resources
├── sops.nix        # Secrets (if needed for API keys)
└── modules/
    └── arr.nix     # Sonarr, Radarr, Bazarr service config
```

### 3.3 microvm.nix

```nix
microvm.hypervisor = "cloud-hypervisor";
microvm.vsock.cid = <next-available>;

microvm.shares = [
  {
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  }
  {
    source = "/persist/guests/bose/static";
    mountPoint = "/static";
    tag = "static";
    proto = "virtiofs";
  }
  {
    # ZFS media pool — virtiofs passthrough for local hardlink support
    source = "/data/media";
    mountPoint = "/media";
    tag = "media";
    proto = "virtiofs";
  }
];

microvm.volumes = [{
  autoCreate = true;
  mountPoint = "/persist";
  image = "/persist/guests/bose/images/persist.img";
  size = 10 * 1024;  # 10GB for arr databases
}];

microvm.mem = 8192;  # 8GB (Radarr is memory-hungry)
microvm.vcpu = 2;
microvm.interfaces = [{
  type = "tap";
  id = "vm-21-bose";
  mac = "<generated>";
}];
```

### 3.4 modules/arr.nix

```nix
inherit (pkgs.mmell.lib.data.users) media;

users.groups.media.gid = media.gid;  # 400, from centralized registry
users.users.media = { inherit (media) uid; group = "media"; isSystemUser = true; };

services.sonarr = { enable = true; group = "media"; };
services.radarr = { enable = true; group = "media"; };
services.bazarr = { enable = true; group = "media"; };

# Deprioritize to avoid starving NAS workloads
systemd.services.sonarr.serviceConfig = { Nice = 19; IOSchedulingClass = "idle"; CPUWeight = 10; };
systemd.services.radarr.serviceConfig = { Nice = 19; IOSchedulingClass = "idle"; CPUWeight = 10; };
```

### 3.5 default.nix

- Static IP from network registry (lab zone)
- SSH keys: deploy, edith
- Egress filtering: DNS (gateway), Loki (tharbad), HTTP/HTTPS (gateway for metadata lookups — TVDB, TMDB, etc.), Jellyfin API (oracion on DMZ port 8096)
- Impermanence: persist `/var/lib/sonarr`, `/var/lib/radarr`, `/var/lib/bazarr`, `/var/log`
- Promtail + node-exporter enabled
- **Swap: 4GB via `zramSwap`** as a pressure valve for Radarr's memory spikes during bulk imports (spec line 156). zramSwap is simplest in a microvm — no disk image space needed.

### 3.6 Router firewall — no changes needed

The lab zone already has `accessTo = ["management" "lab" "dmz" "external"]` in `hosts/thebeyond/router.nix:340`. The arr guest on lab VLAN 21 can reach Jellyfin on DMZ VLAN 100 (port 8096) without any router config changes.

### 3.7 Monitoring integration

**File: `hosts/calvard/microvm/guests/tharbad/modules/prometheus.nix`** — Add bose to Prometheus scrape targets; rename remiferia→liberl, ardent→zeiss; remove monrain/ruan.

**File: `hosts/calvard/microvm/guests/tharbad/modules/loki.nix`** — Update expected host count comment.

**File: `hosts/calvard/microvm/guests/tharbad/default.nix`** — Add bose to extraHosts list; rename existing entries.

---

## Phase 4: Calvard/Jellyfin Fixes

**Goal:** Fix NFS mount and Jellyfin configuration to match the spec.

### 4.1 Fix calvard NFS mount

**File: `hosts/calvard/default.nix`**

Change from:

```nix
fileSystems."/mnt/media" = {
  device = "liberl.internal:/data/media";
  fsType = "nfs";
  options = ["x-systemd.automount" "noauto" "_netdev" "nfsvers=4" "soft" "timeo=150"];
};
```

To:

```nix
fileSystems."/mnt/media" = {
  device = "liberl.internal:/export/ro/media";
  fsType = "nfs";
  options = [
    "nfsvers=4.2" "hard" "ro" "noatime"
    "rsize=1048576" "timeo=600" "retrans=2"
    "nofail" "_netdev"
    "x-systemd.automount" "noauto"
    "x-systemd.idle-timeout=0"
  ];
};
```

Key changes: `soft`→`hard`, `rw`→`ro`, use `/export/ro/media` (server-enforced read-only), NFS 4.2.

### 4.2 Fix erebonia NFS mount

**File: `hosts/erebonia/default.nix`**

Change from:

```nix
fileSystems."/mnt/data" = {
  device = "liberl.internal:/data/data";
  fsType = "nfs";
  options = ["x-systemd.automount" "noauto" "_netdev" "nfsvers=4" "soft" "timeo=150"];
};
```

To (RW mount for encoding — Unmanic will need this later):

```nix
fileSystems."/mnt/media" = {
  device = "liberl.internal:/export/rw/media";
  fsType = "nfs";
  options = [
    "nfsvers=4.2" "hard" "noatime"
    "rsize=1048576" "wsize=1048576"
    "timeo=600" "retrans=2"
    "nofail" "_netdev"
    "x-systemd.automount" "noauto"
    "x-systemd.idle-timeout=0"
  ];
};
```

Key changes: `soft`→`hard`, NFS 4.2, proper buffer sizes, device changed from `/data/data` (removed export) to `/export/rw/media`.

### 4.3 Oracion virtiofs mount point — no change needed

**File: `hosts/calvard/microvm/guests/oracion/microvm.nix`** — unchanged.

Since both the RW and RO exports bind the same root (`/data/media`), path equivalence is trivial:

- **bose** (arr guest): virtiofs `/data/media` → `/media`. Radarr sees `/media/library/movies/...`
- **oracion** (Jellyfin): virtiofs `/mnt/media` (NFS of `/data/media`) → `/media`. Jellyfin sees `/media/library/movies/...`

Both guests see identical paths. The existing virtiofs config (`source = "/mnt/media"`, `mountPoint = "/media"`) is already correct.

### 4.4 Fix Jellyfin configuration

**File: `hosts/calvard/microvm/guests/oracion/modules/jellyfin.nix`**

Add:

```nix
# Disable .NET file locking (breaks on NFS)
systemd.services.jellyfin.environment.DOTNET_SYSTEM_IO_DISABLEFILELOCKING = "true";

# GPU access for VAAPI hardware acceleration
users.users.jellyfin.extraGroups = [ "render" "video" "acme-cert" ];  # add render + video

# Media group for consistent UID
services.jellyfin.group = "media";
users.groups.media.gid = 1500;
```

---

## Phase 5: Post-Deployment Steps (manual, app-level)

These are not NixOS config changes but required setup in service web UIs after deployment:

1. **Sonarr/Radarr → Jellyfin notifications**: In both Sonarr and Radarr (Settings → Connect), add a Jellyfin connection:
   - Host: oracion IP (from network registry), Port: 8096
   - API Key: from Jellyfin dashboard
   - Update Library: enabled
   - Send Notifications: disabled (broken in modern Jellyfin)

2. **Jellyfin VAAPI setup**: Dashboard → Playback → Transcoding, set hardware acceleration to **VAAPI**, device to `/dev/dri/renderD128`. Verify with `intel_gpu_top` — activity on the `Video` row confirms hardware decode.

3. **Jellyfin library setup**: Dashboard → Libraries, add:
   - Movies library → `/media/library/movies`
   - TV library → `/media/library/tv`
   - Music library → `/media/library/music` (if using Jellyfin for music)

4. **Jellyfin scheduled library scan**: Dashboard → Scheduled Tasks, set full library scan every 4-6 hours as inotify fallback (inotify does not work on NFS).

5. **Media directory ownership**: `chown -R 1500:1500 /data/media`

6. **Media directory structure**: Create the staging directories (`manual/`, `torrents/`, `usenet/`, `library/` with subdirectories)

---

## Phase 6: Verification

### Build checks

```bash
# Verify all configs evaluate
./scripts/run-checks.sh host-eval-liberl host-eval-calvard host-eval-erebonia

# Verify disko profile (both variants)
nix build .#checks.x86_64-linux.disko-btrfs
nix build .#checks.x86_64-linux.disko-btrfs-l2arc  # if added as separate check
```

### Post-deployment verification

1. **Liberl boot**: Verify btrfs root, impermanence working, ZFS `data` pool imported, L2ARC attached
2. **NFS exports**: `showmount -e liberl` — verify symmetric RO/RW media exports, no `/data/data` exports
3. **Arr guest**: Verify Sonarr/Radarr/Bazarr web UIs accessible, `/media` virtiofs mounted, swap active
4. **Hardlink test**: Create test file in `/media/manual/movies/`, use Radarr manual import, verify hardlink (not copy)
5. **Jellyfin**: Verify NFS mount is RO+hard, media visible at `/media/library/`, VAAPI working (`intel_gpu_top`)
6. **Path equivalence**: Radarr (bose) and Jellyfin (oracion) both resolve `/media/library/movies/...` to the same data
7. **Erebonia NFS**: Verify `/mnt/media` mounts with hard + RW to `/export/rw/media`

---

## Future Goals (out of scope)

Services and capabilities deferred from this plan for follow-up work:

- **Retro gaming**: [Retrom](https://github.com/JMBeresford/retrom) (publishes a Nix flake) for ROM library management and metadata scraping. The original spec proposed RomM, but it's not packaged in nixpkgs and is limited to browser-based emulation. Retrom is a better fit. Use [Igir](https://github.com/emmercm/igir) for ROM ingestion — it handles DAT-based verification, renaming, and deduplication into the `/media/library/roms/` directory structure. The spec's RomM-specific details (EmulatorJS, IGDB scraping, directory layout) should be revisited against Retrom's capabilities.
- **Unmanic on erebonia**: SVT-AV1 background re-encoding. Erebonia's RW NFS mount is already prepared. Add dirty page tuning (`vm.dirty_bytes = 67108864`, `vm.dirty_background_bytes = 33554432`) when this is implemented.
- **Navidrome**: Dedicated music streaming server on calvard (RO NFS).
- **Caddy**: Reverse proxy + TLS termination on calvard, fronting all client-facing services.
- **Audiobookshelf / Kavita / Immich**: Optional media servers per the spec.
- **Dedicated backup service**: Remiferia's root user currently holds an SSH key for manual off-site backups. With the reformat, root's key is removed (liberl uses the host key for internal SSH, matching erebonia/calvard). The backup key needs to migrate to a dedicated `backup` system user with its SSH key managed via sops (decrypted to `/run/secrets/backup-ssh-key`). Scope the key to the backup provider via `programs.ssh.extraConfig`. The backup user needs read access to `/data/` datasets (group membership or ZFS ACLs). This is a fast follow-up — the reformat is the forcing function, but the backup service design (scheduling, tool choice, monitoring) deserves its own plan.
- **SMB media share rework**: Current SMB config gives full RW access to `/data/media` from the trusted VLAN, contradicting the least-privilege model. Needs a broader upload workflow redesign.
- **Optional bose enhancements**: Lidarr (music organization), Recyclarr (TRaSH Guide quality profile sync to Sonarr/Radarr). Add to bose when needed.
- **One-time migration tools**: FileBot (bulk media renaming into `/media/library/<type>/` for arr Library Import; supports multi-episode files and DVD/absolute orderings, requires paid license), MusicBrainz Picard (music tag correction). Run on bose during migration.

---

## Files Modified (Summary)

| File                                                          | Action                                                                                                    |
| ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------- |
| `profiles/disko/btrfs.nix`                                    | Add optional `l2arcSize` parameter                                                                        |
| `tests/default.nix`                                           | Add disko-btrfs-l2arc check                                                                               |
| `hosts/remiferia/` → `hosts/liberl/`                          | **Rename** entire directory                                                                               |
| `hosts/liberl/default.nix`                                    | Rename host, new hostId, disko import (with l2arcSize), impermanence, VLAN 21 bridge                      |
| `hosts/liberl/hardware-configuration.nix`                     | Strip filesystem declarations (keep kernel/CPU/initrd)                                                    |
| `hosts/liberl/impermanence.nix`                               | **New** — persistence declarations                                                                        |
| `hosts/liberl/nas.nix`                                        | NFS export hardening, media user, bind mount fix, remove unused exports, Samba name → LIBERL              |
| `hosts/liberl/microvm/guests/zeiss/microvm.nix`               | Update paths `/data/guests/` → `/persist/guests/` (née ardent)                                            |
| `hosts/liberl/microvm/guests/ruan/`                           | **Deleted** — cgit guest eliminated; all git repos on creil (Forgejo)                                     |
| `hosts/liberl/microvm/guests/bose/`                           | **New** — arr stack guest (4-5 files)                                                                     |
| `lib/common/data/network.nix`                                 | Rename hosts (remiferia→liberl, ardent→zeiss); remove monrain/ruan; add bose to lab zone, add hostAliases |
| `hosts/calvard/default.nix`                                   | Fix NFS mount (hard, RO, proper options, liberl.internal)                                                 |
| `hosts/calvard/microvm/guests/oracion/microvm.nix`            | No change needed (path equivalence preserved by symmetric exports)                                        |
| `hosts/calvard/microvm/guests/oracion/modules/jellyfin.nix`   | .NET file locking fix, render/video groups, media group                                                   |
| `hosts/calvard/microvm/guests/tharbad/modules/prometheus.nix` | Add bose scrape target, rename existing targets                                                           |
| `hosts/calvard/microvm/guests/tharbad/modules/loki.nix`       | Update host count                                                                                         |
| `hosts/calvard/microvm/guests/tharbad/default.nix`            | Add bose to extraHosts, rename existing entries                                                           |
| `hosts/erebonia/default.nix`                                  | Fix NFS mount (hard, RW media, proper options, liberl.internal)                                           |
| `flake.nix`                                                   | Rename nixosConfigurations.remiferia → .liberl, add disko module                                          |
| `docs/hostnames.md`                                           | Move liberl to NAS host, update guest assignments, remove remiferia entry                                 |
