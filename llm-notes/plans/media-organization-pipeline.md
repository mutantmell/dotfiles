# Media Organization Pipeline - Implementation Plan

## Context

The spec at `llm-notes/specs/jellyfin-media-organization.md` defines a media pipeline architecture with least-privilege NFS separation: write-access services (arr stack) on the NAS, read-only serving (Jellyfin) on a separate node. This maps cleanly to the existing infrastructure:

| Spec Role | Host | Status |
|-----------|------|--------|
| NAS (arr stack, NFS) | **remiferia** | Needs disko reformat + new arr guest |
| Serving node (Jellyfin, RomM) | **calvard** (oracion guest) | Partially done, needs fixes |
| Encoding node (Unmanic) | **erebonia** | Future work (out of scope) |

The core deliverable is: remiferia reformatted with btrfs/impermanence, a new arr stack microvm, hardened NFS exports, and Jellyfin configuration fixes on calvard.

---

## Phase 1: Remiferia Disko Reformat

**Goal:** Replace ext4 root with btrfs + impermanence + L2ARC partition, preserving the ZFS `data` pool.

### 1.1 Extend the existing btrfs disko profile

Add an optional `l2arcSize` parameter to `profiles/disko/btrfs.nix`. When set, disko creates a third partition (raw, no filesystem) between the ESP and the LUKS partition, sized for use as a ZFS L2ARC cache device. When unset (default), behavior is unchanged — erebonia and calvard are unaffected.

**File: `profiles/disko/btrfs.nix`**

Current signature: `{disk ? "/dev/sda", ...}`
New signature: `{disk ? "/dev/sda", l2arcSize ? null, ...}`

When `l2arcSize` is non-null (e.g. `"32G"`), add a partition:
```nix
l2arc = {
  name = "l2arc";
  size = l2arcSize;  # e.g. "32G"
  content.type = "zfs_member";  # or just leave raw — ZFS manages it via zpool add
};
```

The L2ARC keeps frequently-accessed ZFS metadata and small files warm on the SSD, allowing HDD spindown between actual media operations (spec line 369). This must be done at initial partitioning time to avoid repartitioning later.

**Note:** The actual `zpool add data cache /dev/sdXN` is a one-time manual step after first boot, not managed by disko. The partition just needs to exist. Consider whether to leave it raw (simplest) or use `content.type = "zfs_member"` for documentation purposes.

### 1.2 Update remiferia host config

**Files to modify:**
- `hosts/remiferia/default.nix` — Replace `hardware-configuration.nix` filesystem declarations with disko profile import, enable impermanence + btrfs modules
- `hosts/remiferia/hardware-configuration.nix` — Strip filesystem declarations (keep kernel modules, CPU microcode, `nixpkgs.hostPlatform`, initrd modules)
- `flake.nix` — Add `disko.nixosModules.disko` to remiferia's module list

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

**New file: `hosts/remiferia/impermanence.nix`**

Standard persisted paths (matching other hosts):
- `/var/log`, `/var/lib/nixos`, `/var/lib/systemd/coredump`

NAS-specific:
- `/var/lib/samba` (Samba state/databases)

ZFS pool auto-imports via `boot.zfs.extraPools = ["data"]` (already in `default.nix`, unchanged). `networking.hostId = "9f034bc8"` (already in `default.nix`, unchanged).

### 1.4 Update microvm guest paths

Currently ardent/monrain use `/data/guests/{name}/` for static shares and disk images. After disko reformat, these should move to `/persist/guests/{name}/` (on btrfs SSD) to match the convention and keep VM boot off the HDDs.

**Files:**
- `hosts/remiferia/microvm/guests/ardent/microvm.nix` — Update paths `/data/guests/` → `/persist/guests/`
- `hosts/remiferia/microvm/guests/monrain/microvm.nix` — Update paths `/data/guests/` → `/persist/guests/`

### 1.5 Deployment procedure (manual, not code changes)

1. Backup remiferia config + guest static dirs + guest disk images
2. Boot from NixOS installer USB
3. `zpool export data` (safely detach ZFS pool)
4. Run disko to partition the boot SSD (creates ESP + L2ARC + LUKS/btrfs)
5. Install NixOS with new config
6. `zpool import data` (re-import on first boot via `boot.zfs.extraPools`)
7. `zpool add data cache /dev/sdXN` (add L2ARC partition — one-time)
8. Restore guest static directories to `/persist/guests/`
9. Verify services come up

### 1.6 Add disko check

Update the `disko-btrfs` check in `tests/default.nix` to also test the `l2arcSize` parameter variant, or add a second check `disko-btrfs-l2arc`.

---

## Phase 2: NFS Export Hardening

**Goal:** Implement the spec's RO/RW separation with per-host access and UID squashing.

### 2.1 Create media directory structure

On remiferia host (one-time manual setup on the ZFS pool):
```
/data/media/
├── torrents/{movies,tv,music}/
├── usenet/complete/{movies,tv,music}/
├── manual/{movies,tv,music}/
└── library/{movies,tv,music,roms/{gba,gbc,snes,n64,ps,ps2,gc}}/
```

### 2.2 Update NFS exports and bind mounts

**File: `hosts/remiferia/nas.nix`**

Change bind mounts:
- `/export/rw/media` binds to `/data/media` (full tree, unchanged)
- `/export/ro/media` binds to `/data/media/library` (**currently binds to `/data/media`** — this is the key security fix)

Remove unused exports and bind mounts:
- Remove `/export/rw/data`, `/export/ro/data`, `/export/rw/backup` bind mounts
- Remove `/data/data`, `/data/media` direct exports (replaced by `/export/` tree)

New export config using per-host access and UID squashing:
```nix
services.nfs.server.exports = ''
  /export/rw/media  erebonia-ip(rw,sync,no_subtree_check,all_squash,anonuid=1500,anongid=1500)
  /export/ro/media  calvard-ip(ro,sync,no_subtree_check,all_squash,anonuid=1500,anongid=1500)
'';
```

Key changes from current config:
- **Replace `no_root_squash` with `all_squash,anonuid=1500,anongid=1500`** — eliminates UID mismatches
- **Per-host access instead of subnet-wide** — only specific hosts that need access
- **RO export scoped to `library/`** — calvard can't see staging directories
- **Remove unused non-media exports** (`/data/data`, `/export/rw/backup`, etc.)

**SMB shares are left unchanged** — replacing them requires a broader change to the upload workflow.

### 2.3 Create media user/group

**File: `hosts/remiferia/nas.nix`** (and arr guest config)

```nix
users.groups.media.gid = 1500;
users.users.media = { uid = 1500; group = "media"; isSystemUser = true; };
```

Ensure `/data/media` ownership is `media:media` (1500:1500) — one-time manual `chown -R 1500:1500 /data/media`.

### 2.4 Update firewall rules

Update NFS firewall in `nas.nix` to match the new per-host export pattern. Replace subnet-wide rules with specific host IPs (calvard for RO, erebonia for RW).

---

## Phase 3: Arr Stack Microvm (denai)

**Goal:** New microvm on remiferia running Sonarr, Radarr, Bazarr with virtiofs access to `/data/media`.

### 3.1 Network setup

**Add VLAN 21 (lab) to remiferia networking:**

**File: `hosts/remiferia/default.nix`** — Add:
- `enp4s0.21` VLAN netdev
- `br21` bridge
- Network matching `vm-21-*` tap interfaces to `br21`

**File: `lib/common/data/network.nix`** — Add host entry:
```nix
lab = {
  vlanId = 21;
  hosts = {
    edith = 42;
    denai = XX;  # pick next available ID
  };
};
```

### 3.2 Create guest directory structure

```
hosts/remiferia/microvm/guests/denai/
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
    source = "/persist/guests/denai/static";
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
  image = "/persist/guests/denai/images/persist.img";
  size = 10 * 1024;  # 10GB for arr databases
}];

microvm.mem = 8192;  # 8GB (Radarr is memory-hungry)
microvm.vcpu = 2;
microvm.interfaces = [{
  type = "tap";
  id = "vm-21-denai";
  mac = "<generated>";
}];
```

### 3.4 modules/arr.nix

```nix
users.groups.media.gid = 1500;
users.users.media = { uid = 1500; group = "media"; isSystemUser = true; };

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
- **Swap: 4GB** as a pressure valve for Radarr's memory spikes during bulk imports (spec line 156). Configure via `swapDevices` on the persist volume or `zramSwap`.

### 3.6 Router firewall — no changes needed

The lab zone already has `accessTo = ["management" "lab" "dmz" "external"]` in `hosts/thebeyond/router.nix:340`. The arr guest on lab VLAN 21 can reach Jellyfin on DMZ VLAN 100 (port 8096) without any router config changes.

### 3.7 Monitoring integration

**File: `hosts/calvard/microvm/guests/tharbad/modules/prometheus.nix`** — Add denai to Prometheus scrape targets.

**File: `hosts/calvard/microvm/guests/tharbad/modules/loki.nix`** — Update expected host count comment.

**File: `hosts/calvard/microvm/guests/tharbad/default.nix`** — Add denai to extraHosts list.

---

## Phase 4: Calvard/Jellyfin Fixes

**Goal:** Fix NFS mount and Jellyfin configuration to match the spec.

### 4.1 Fix calvard NFS mount

**File: `hosts/calvard/default.nix`**

Change from:
```nix
fileSystems."/mnt/media" = {
  device = "remiferia.internal:/data/media";
  fsType = "nfs";
  options = ["x-systemd.automount" "noauto" "_netdev" "nfsvers=4" "soft" "timeo=150"];
};
```

To:
```nix
fileSystems."/mnt/media" = {
  device = "remiferia.internal:/export/ro/media";
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

Key changes: `soft`→`hard`, `rw`→`ro`, scoped to `/export/ro/media` (library only), NFS 4.2.

### 4.2 Fix erebonia NFS mount

**File: `hosts/erebonia/default.nix`**

Change from:
```nix
fileSystems."/mnt/data" = {
  device = "remiferia.internal:/data/data";
  fsType = "nfs";
  options = ["x-systemd.automount" "noauto" "_netdev" "nfsvers=4" "soft" "timeo=150"];
};
```

To (RW mount for encoding — Unmanic will need this later):
```nix
fileSystems."/mnt/media" = {
  device = "remiferia.internal:/export/rw/media";
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

### 4.3 Update oracion virtiofs mount point

**File: `hosts/calvard/microvm/guests/oracion/microvm.nix`**

The host mount changes from `/mnt/media` (full tree) to `/mnt/media` (now library-only from NFS). The virtiofs share source stays `/mnt/media` but the guest mount point should be `/media/library` to match path equivalence:

```nix
{
  source = "/mnt/media";
  mountPoint = "/media/library";  # was "/media"
  tag = "media";
  proto = "virtiofs";
}
```

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

2. **Jellyfin scheduled library scan**: Dashboard → Scheduled Tasks, set full library scan every 4-6 hours as inotify fallback (inotify does not work on NFS).

3. **ZFS L2ARC**: `zpool add data cache /dev/sdXN` (one-time, after first boot)

4. **Media directory ownership**: `chown -R 1500:1500 /data/media`

5. **Media directory structure**: Create the staging directories (`manual/`, `torrents/`, `usenet/`, `library/` with subdirectories)

---

## Phase 6: Verification

### Build checks
```bash
# Verify all configs evaluate
./scripts/run-checks.sh host-eval-remiferia host-eval-calvard host-eval-erebonia

# Verify disko profile (both variants)
nix build .#checks.x86_64-linux.disko-btrfs
nix build .#checks.x86_64-linux.disko-btrfs-l2arc  # if added as separate check
```

### Post-deployment verification
1. **Remiferia boot**: Verify btrfs root, impermanence working, ZFS `data` pool imported, L2ARC attached
2. **NFS exports**: `showmount -e remiferia` — verify RO export scoped to library, no `/data/data` exports
3. **Arr guest**: Verify Sonarr/Radarr/Bazarr web UIs accessible, `/media` virtiofs mounted, swap active
4. **Hardlink test**: Create test file in `/media/manual/movies/`, use Radarr manual import, verify hardlink (not copy)
5. **Jellyfin**: Verify NFS mount is RO+hard, media visible at `/media/library/`, VAAPI working (`intel_gpu_top`)
6. **Path equivalence**: Radarr reports `/media/library/movies/...`, Jellyfin resolves same path
7. **Erebonia NFS**: Verify `/mnt/media` mounts with hard + RW to `/export/rw/media`

---

## Files Modified (Summary)

| File | Action |
|------|--------|
| `profiles/disko/btrfs.nix` | Add optional `l2arcSize` parameter |
| `tests/default.nix` | Add disko-btrfs-l2arc check |
| `hosts/remiferia/default.nix` | Disko import (with l2arcSize), impermanence, VLAN 21 bridge |
| `hosts/remiferia/hardware-configuration.nix` | Strip filesystem declarations (keep kernel/CPU/initrd) |
| `hosts/remiferia/impermanence.nix` | **New** — persistence declarations |
| `hosts/remiferia/nas.nix` | NFS export hardening, media user, bind mount fix, remove unused exports |
| `hosts/remiferia/microvm/guests/ardent/microvm.nix` | Update paths `/data/guests/` → `/persist/guests/` |
| `hosts/remiferia/microvm/guests/monrain/microvm.nix` | Update paths `/data/guests/` → `/persist/guests/` |
| `hosts/remiferia/microvm/guests/denai/` | **New** — arr stack guest (4-5 files) |
| `lib/common/data/network.nix` | Add denai to lab zone |
| `hosts/calvard/default.nix` | Fix NFS mount (hard, RO, library-scoped) |
| `hosts/calvard/microvm/guests/oracion/microvm.nix` | Fix virtiofs mount point → `/media/library` |
| `hosts/calvard/microvm/guests/oracion/modules/jellyfin.nix` | .NET file locking fix, render/video groups, media group |
| `hosts/calvard/microvm/guests/tharbad/modules/prometheus.nix` | Add denai scrape target |
| `hosts/calvard/microvm/guests/tharbad/modules/loki.nix` | Update host count |
| `hosts/calvard/microvm/guests/tharbad/default.nix` | Add denai to extraHosts |
| `hosts/erebonia/default.nix` | Fix NFS mount (hard, RW media, proper options) |
| `flake.nix` | Add disko module to remiferia |
| `docs/hostnames.md` | Mark denai as allocated |
