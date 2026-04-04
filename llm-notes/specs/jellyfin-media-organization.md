# Self-Hosted Media & Games Homelab Architecture

## Overview

This document consolidates the design decisions, rationale, tooling, and machine assignments for a self-hosted media and games homelab built on NixOS with microvms. The architecture is built around three physical nodes:

- **NAS** — storage server; exports media over NFS, runs the *arr stack in a microvm
- **Old machine** — encoding node; runs Unmanic for background SVT-AV1 re-encoding
- **New machine** — serving node; handles all latency-sensitive, client-facing services

The guiding principle is **least-privilege separation**: services that need write access to the media filesystem are isolated from externally-accessible services, which operate exclusively against a read-only NFS export.

### Why Each Machine Does What It Does

**NAS** has abundant RAM but slow CPU. The *arr stack (Sonarr, Radarr, Bazarr) is primarily a memory and I/O workload — loading, sorting, and cross-referencing metadata in SQLite databases — not a compute workload. Running it on the NAS also means hardlink operations (staging → library) happen via virtiofs as local kernel operations on the host filesystem rather than over NFS, which is the ideal configuration.

**Old machine** has middling CPU and is not latency-sensitive. SVT-AV1 software encoding via Unmanic is compute-intensive but not time-sensitive — it runs as a background job for weeks. It reads source files and writes encoded output over the RW NFS mount, which is acceptable since large sequential file I/O over NFS is far less problematic than the random small I/O that makes NFS painful for databases.

**New machine** (System76 Meerkat, 2023, 12th gen Intel Alder Lake) has the best CPU and Intel Xe integrated graphics with VAAPI AV1 hardware decode. It handles all latency-sensitive serving: Jellyfin, RomM, Navidrome, Caddy. Hardware-accelerated AV1 decode via VAAPI means direct playback of re-encoded content uses the GPU rather than burning CPU cycles.

---

## Storage Layout

### NFS Export Structure

The NAS uses bind mounts to expose a clean, access-level-explicit export tree. All NFS exports live under `/export/`, subdivided by access level:

```
/export/
├── rw/
│   └── media      ← bind mount of /data/media        (NAS microvm + old machine, read-write)
└── ro/
    └── media      ← bind mount of /data/media/library (new machine, read-only)
```

This pattern makes the access inventory self-documenting — everything under `/export/rw/` is writable, everything under `/export/ro/` is read-only. Auditing what is exposed over NFS is simply `ls /export/rw/` and `ls /export/ro/`.

The read-only export is scoped to just the `library/` subdirectory — the organized, triaged collection. The new machine has no visibility into staging, incoming, or download directories.

The *arr stack microvm on the NAS accesses the media filesystem via **virtiofs** passthrough rather than NFS — the ZFS pool is mounted on the NAS host and shared directly into the microvm. The old machine and any other RW clients access it via the NFS RW export.

> **Bind mount caveat:** a plain `bind` mount does not cross filesystem boundaries. If your NAS uses nested ZFS datasets (e.g., `data/media` and `data/media/library` as separate datasets), the bind mount of the parent will not include the child dataset. Verify your NAS layout uses a single dataset with subdirectories, or use `rbind` and ensure NFS `subtree_check` behavior is as expected.

### Path Equivalence Between RW and RO Mounts

The RW and RO exports bind mount different subdirectories of the pool, but this asymmetry is intentional and path equivalence is preserved through compensating mount points on each machine:

```
NAS microvm:  /data/media         → mounted at /media          (full RW tree via virtiofs)
Old machine:  /data/media         → mounted at /media          (full RW tree via NFS)
New machine:  /data/media/library → mounted at /media/library  (RO subtree only via NFS)
```

Sonarr and Radarr on the NAS microvm report paths like `/media/library/tv/Show/...` to Jellyfin when triggering a scan. Jellyfin on the new machine mounts the RO export at `/media/library`, so it resolves `/media/library/tv/Show/...` to the same underlying data. The paths match without any remote path mapping configuration.

The narrower bind mount scope on the RO export (scoped to `library/` rather than the full `media/` tree) is what prevents the new machine from seeing staging directories like `manual/`, `torrents/`, and `usenet/`. The mount point offset on the new machine (`/media/library` rather than `/media`) compensates exactly for this narrower scope. The two asymmetries cancel out, producing consistent paths across all machines while preserving the security boundary.

If both exports were bound to the same root (`/data/media`) and both machines mounted at `/media`, path equivalence would be even more explicit — but the new machine would gain visibility into staging directories, which is undesirable. The current design is intentional.

### NAS-Side Directory Structure

All directories live under a single root on a **single server-side filesystem** (one ZFS dataset). The ZFS pool is named `data`; the media dataset is `data/media`, mounted at `/data/media` on the NAS host. This is a hard requirement for hardlinks to function — separate datasets break hardlinks even if they appear as subdirectories.

```
/data/media/                   ← single ZFS dataset (data/media); virtiofs root (NAS microvm) + RW export root
├── torrents/                  ← download client output (if used)
│   ├── movies/
│   ├── tv/
│   └── music/
├── usenet/                    ← alternative download client output
│   └── complete/
│       ├── movies/
│       ├── tv/
│       └── music/
├── manual/                    ← manually uploaded files (staging inbox)
│   ├── movies/
│   ├── tv/
│   └── music/
└── library/                   ← organized library; RO export root
    ├── movies/
    ├── tv/
    ├── music/
    └── roms/
        ├── gba/
        ├── gbc/
        ├── snes/
        ├── n64/
        ├── ps/
        ├── ps2/
        └── gc/
```

The name `library/` distinguishes the organized, triaged collection from the staging areas above it. The export name `media` describes the purpose of the share at the NAS level. These are two separate naming concerns at two different levels — the internal directory name reflects pipeline stage, the export name reflects the share's domain.

### Why `library/` and Not `media/`

The TRaSH Guides convention uses `media/` for the organized directory, which produces a redundant `/media/media/` path when the export itself is named `media`. Renaming the internal directory to `library/` resolves this without any behavioral impact on the tools — Sonarr, Radarr, Jellyfin, and RomM all operate against configurable root paths.

### Why Hardlinks Require a Single Filesystem

When Radarr or Sonarr imports a file, it creates a hardlink from the staging area (e.g., `/media/manual/movies/`) to the organized library (`/media/library/movies/`). Hardlinks are inode aliases — they only work within a single filesystem. The kernel's `link()` syscall returns `EXDEV` if source and destination are on different devices.

The *arr stack microvm on the NAS accesses the filesystem via virtiofs, which passes hardlink operations through to the host ZFS filesystem as local kernel calls. This is correct and efficient. The old machine performs no hardlink operations — it only reads source files and writes encoded output in place via Unmanic.

---

## Why This Architecture

### Security Boundary

External-facing services (Jellyfin, RomM) run on the new machine with read-only NFS access. Even if these services are compromised, they cannot modify the media filesystem. All write operations are confined to the NAS microvm (library management) and old machine (encoding), neither of which is externally accessible.

The bind mount export pattern reinforces this: the new machine is pointed at `nas:/export/ro/media`, which the NAS kernel enforces as read-only at the export level — not just via mount options on the client.

### Resource Matching

Each machine's workload matches its hardware profile:

| Machine | Strength | Workload |
|---------|----------|----------|
| NAS | Abundant RAM | *arr stack — memory-heavy metadata/database operations |
| Old machine | Middling CPU, not latency-sensitive | Unmanic — SVT-AV1 software encoding, background batch job |
| New machine | Best CPU, Intel Xe VAAPI AV1 decode | Jellyfin, RomM, Navidrome — latency-sensitive serving |

### Alignment with Jellyfin's Architecture

Jellyfin has no built-in file organization or renaming capability. It reads whatever directory structure it is given. The *arr stack produces exactly the directory layout Jellyfin's metadata plugins expect, so the two layers are cleanly separated by design.

---

## Services

### NAS Microvm (Read-Write via virtiofs, Batch Library Management)

| Service | Purpose | Notes |
|---------|---------|-------|
| **Sonarr** | TV show organization, renaming, import | Manages `/media/library/tv/` |
| **Radarr** | Movie organization, renaming, import | Manages `/media/library/movies/` |
| **Bazarr** | Subtitle downloading | Writes `.srt` files into `/media/library/` |
| **Lidarr** | Music organization (optional) | Manages `/media/library/music/` |
| **mnamer** | One-time bulk renaming of existing unorganized library | Run once during migration |
| **MusicBrainz Picard** | Music tag correction (optional) | Run once during migration |

The NAS microvm accesses the ZFS pool via virtiofs passthrough from the host. Persistent state (Radarr/Sonarr databases, configuration) is declared via microvm.nix impermanence and stored in a persistent btrfs subvolume on the NAS host, separate from the ZFS media pool. Guest images and NixOS store paths live on the btrfs root SSD, ensuring VM boot and *arr stack binary access never spin up the HDDs.

#### RAM Allocation for NAS Microvm

| Service | Idle | Active peak | Trigger |
|---------|------|-------------|---------|
| Sonarr | 150–250 MB | 400–600 MB | RSS scan, import, rename batch |
| Radarr | 500 MB–1.5 GB | 2–4 GB (small library) / 4–12 GB (large library) | List import, bulk rename |
| Bazarr | 100–265 MB | 300–500 MB | Library-wide subtitle sync |
| Lidarr | 200–400 MB | 500 MB–1 GB | Album import, metadata refresh |

**Recommended allocation: 8 GB minimum, 16 GB for large movie libraries.** Radarr is the dominant consumer and scales with library size. Provision swap on the microvm as a pressure valve for Radarr's infrequent bulk operation spikes — 4 GB of swap means Radarr operations complete slowly rather than failing outright when RAM is constrained.

Note: Radarr's largest spikes occur during initial library import of a large existing collection. This is a one-time event — consider temporarily increasing the microvm's RAM allocation during first ingestion of a large existing collection, then reducing it to steady-state sizing afterward.

#### Sonarr / Radarr

These are the core of the organization layer. They handle:

- Renaming files into Jellyfin-compatible directory structures
- Hardlinking files from staging areas (`/media/manual/`, `/media/torrents/`) into the organized library
- Notifying Jellyfin via HTTP API when new media is imported
- Managing upgrades and deletions

**Jellyfin connection configuration** (in both Sonarr and Radarr under Settings → Connect):

- Host: new machine IP
- Port: 8096
- API Key: generated in Jellyfin dashboard
- Update Library: **Enabled**
- Send Notifications: **Disabled** (the notifications endpoint is broken in modern Jellyfin)

This triggers a targeted per-path scan on Jellyfin rather than a full library rescan. The NAS microvm sees paths under `/media/library/` via virtiofs; the new machine mounts the RO export at `/media/library` — paths are consistent with no remote path mapping required. See the Path Equivalence section above for the full explanation.

**Manual Import workflow** for the two upload use cases:

1. Copy files into `/media/manual/movies/` or `/media/manual/tv/` via rsync/scp to the NAS
2. Open Radarr → Movies → Manual Import (or Sonarr equivalent)
3. Point at `/media/manual/`
4. Review and confirm matches, then import

This covers both migrating the old unorganized collection and ongoing uploads from a desktop machine. The `manual/` directory lives above the `library/` subtree and is never visible to Jellyfin or RomM via their read-only mount.

#### Bazarr

Bazarr monitors Sonarr and Radarr's libraries via their APIs and automatically downloads subtitles from OpenSubtitles, Addic7ed, and others. It writes `.srt` files alongside media files in `/media/library/`, which requires write access — this is why it must be co-located with the *arr stack on the NAS microvm.

Jellyfin picks up subtitle files automatically when they appear in the same directory as the video file. No additional configuration is needed.

#### Migration: mnamer

For the one-time migration of an existing unorganized collection:

```bash
# Movies
mnamer -b -r \
  --movie-directory="/media/manual/movies" \
  --movie-format="{name} ({year})/{name} ({year})" \
  /old-library/movies/

# TV
mnamer -b -r \
  --episode-directory="/media/manual/tv" \
  --episode-format="{series} ({year})/Season {season:02}/{series} - S{season:02}E{episode:02} - {title}" \
  /old-library/tv/
```

Run mnamer first to rough-organize files into Jellyfin-compatible naming, then use Sonarr/Radarr Manual Import to ingest them into the managed library. FileBot is a more accurate alternative but is no longer open source (requires a license).

---

### Old Machine (Read-Write NFS, Encoding)

| Service | Purpose | Notes |
|---------|---------|-------|
| **Unmanic** | Background SVT-AV1 re-encoding | Reads/writes `/media/library/` via RW NFS |

Unmanic watches the library, re-encodes files to AV1 using SVT-AV1 software encoding, and replaces originals in place. It runs as a long-term background job — re-encoding a multi-terabyte library takes weeks on middling hardware, which is expected and acceptable.

#### RAM Allocation for Old Machine

| Service | Idle | Active peak | Trigger |
|---------|------|-------------|---------|
| Unmanic | 200–400 MB | 1–2 GB per worker | SVT-AV1 encode (scales with resolution and worker count) |

Active figure is per worker thread. 1080p encodes sit toward the lower end; 4K toward the upper. Configure worker count based on available CPU cores and RAM headroom.

**Recommended allocation: 4 GB for single-worker encoding, 2 GB per additional worker.**

#### Encoding Strategy

Unmanic encodes to a temporary file, then atomically replaces the original on completion. Keep originals in an archive directory until the re-encoded output is verified — with a multi-terabyte library, spot-checking a sample before committing to deletion is prudent.

The old machine mounts the RW NFS export because Unmanic needs to write encoded files back into `/media/library/`. Large sequential file I/O over NFS is well-suited to this workload — unlike the random small I/O of database operations, sequential reads and writes for video files perform well over a gigabit NFS connection.

#### Dirty Page Tuning (Old Machine)

Prevents NFS write buffering from overwhelming the NAS during large file operations:

```nix
boot.kernel.sysctl = {
  "vm.dirty_bytes"            = 67108864;   # 64 MB cap
  "vm.dirty_background_bytes" = 33554432;   # 32 MB background flush
};
```

---

### New Machine (Read-Only NFS, Client-Facing)

| Service | Purpose | Notes |
|---------|---------|-------|
| **Jellyfin** | Video/TV streaming server | Reads `/media/library` via RO NFS |
| **RomM** | ROM library manager + EmulatorJS frontend | Reads `/media/library/roms` via RO NFS |
| **Navidrome** (optional) | Dedicated music streaming | Reads `/media/library/music` via RO NFS |
| **Audiobookshelf** (optional) | Audiobook and podcast server | Reads `/media/library/audiobooks` via RO NFS |
| **Kavita** (optional) | Ebook, comic, and manga library | Reads `/media/library/books` via RO NFS |
| **Immich** (optional) | Photo and video backup | Manages its own storage independently of the media library |
| **Caddy** | Reverse proxy, TLS termination | Fronts all HTTP services |

#### RAM Allocation for New Machine

| Service | Idle | Active peak | Trigger |
|---------|------|-------------|---------|
| Jellyfin | 300–500 MB | +200–400 MB per transcode stream; ~50 MB per direct play stream | Transcode or playback |
| RomM | 100–200 MB | 300–500 MB | Library scan, metadata scrape |
| Navidrome | 50–100 MB | 200–300 MB | Full library rescan |
| Audiobookshelf | 100–200 MB | 300–500 MB | Library scan, chapter detection |
| Kavita | 100–200 MB | 300–600 MB | Library scan, cover generation |
| Immich | 300–600 MB | 1–2 GB | Initial import, face recognition, CLIP indexing |
| Caddy | 20–50 MB | 50–100 MB | High concurrent connections |

**Recommended allocation: 4 GB for core services (Jellyfin + RomM + Caddy), 8 GB with all optional services including Immich.**

Since the target state is direct play of VAAPI-decoded AV1 content, Jellyfin transcoding should rarely trigger. The main exception is clients that don't support AV1 natively — any such client falls back to a software transcode stream adding 200–400 MB per session.

#### Jellyfin

Jellyfin serves movies and TV shows. Key configuration notes for this architecture:

**Disable .NET file locking** — Jellyfin's .NET runtime attempts file locks that cause issues on NFS:

```nix
systemd.services.jellyfin.environment = {
  DOTNET_SYSTEM_IO_DISABLEFILELOCKING = "true";
};
```

**Enable VAAPI hardware acceleration** — Intel Xe requires the `iHD` media driver and render group access:

```nix
hardware.graphics = {
  enable = true;
  extraPackages = with pkgs; [
    intel-media-driver    # iHD driver — required for 11th gen+ / Xe graphics
    intel-compute-runtime # OpenCL, needed for some tone mapping operations
  ];
};

users.users.jellyfin.extraGroups = [ "render" "video" ];
```

Set hardware acceleration to **VAAPI** and device to `/dev/dri/renderD128` in Jellyfin's Dashboard → Playback → Transcoding. Verify with `intel_gpu_top` — activity on the `Video` row (not `Render/3D`) confirms hardware decode is active.

**AV1 decode/encode capability on the Meerkat (meer8, Alder Lake):**
- AV1 hardware **decode**: supported via Intel Xe / Gen 12 media engine
- AV1 hardware **encode**: not supported — requires Arc A-series or Meteor Lake and newer

**Keep Jellyfin's database local** — SQLite does not work reliably on NFS. Only media files are on NFS; Jellyfin's config, database, and cache live on local storage.

**Use hard NFS mounts** — `soft` mounts return errors on timeout, which Jellyfin interprets as files being deleted. Always use `hard`.

**inotify does not work on NFS** — Jellyfin's real-time monitoring relies on inotify, which is a local kernel feature. It will not detect changes on an NFS mount. This is solved entirely by the Sonarr/Radarr API notification described above. As a safety net, configure a scheduled full library scan every 4–6 hours in Jellyfin's Dashboard → Scheduled Tasks.

**Library structure Jellyfin expects:**

| Media type | Expected path format |
|-----------|---------------------|
| Movies | `/media/library/movies/Movie Name (Year)/Movie Name (Year).mkv` |
| TV | `/media/library/tv/Show Name/Season 01/Show Name - S01E01 - Title.mkv` |
| Music | `/media/library/music/Artist/Album/track.flac` (reads embedded tags) |

**TV library subdivision** — Jellyfin supports multiple root folders per library type. For example, separating kids' content from general TV:

```
/media/library/tv/
/media/library/tv-kids/
```

Configure two separate TV libraries in Jellyfin, each pointing at its own root. Assign series to the appropriate root folder in Sonarr during import.

#### RomM

RomM is a self-hosted ROM library manager equivalent in role to Jellyfin but for retro games. It scrapes metadata from IGDB and MobyGames, presents a web UI for browsing, and launches games in-browser via EmulatorJS — no client-side install required.

**In-browser emulation coverage:**

| Platform | Browser emulation | Notes |
|----------|-------------------|-------|
| GBA, SNES, NES, GB/GBC | Excellent | Full speed on any modern device |
| N64 | Good | Most games playable |
| PS1 | Good | Most games playable |
| PS2 | Poor | Inconsistent; many games unplayable at speed |
| GameCube | Poor | Not practically viable in browser today |

**ROM directory structure RomM expects:**

```
/media/library/roms/
├── gba/
├── gbc/
├── snes/
├── n64/
├── ps/
├── ps2/
└── gc/
```

---

## NixOS Configuration

### NAS Host: btrfs Root, ZFS Pool, Bind Mounts, NFS Server

The NAS runs btrfs on the root partition (with impermanence) for better virtiofs integration. Microvm guest images and NixOS store paths live on the btrfs SSD, ensuring HDD spindown is not disrupted by VM boot or *arr stack binary access. The media pool runs ZFS on HDDs. A dedicated partition on the boot SSD serves as an L2ARC cache device, keeping frequently-accessed ZFS metadata and small files warm to allow HDD spindown between actual media operations.

```nix
# Bind mounts into the export tree
fileSystems."/export/rw/media" = {
  device = "/data/media";
  fsType = "none";
  options = [ "bind" ];
};

fileSystems."/export/ro/media" = {
  device = "/data/media/library";
  fsType = "none";
  options = [ "bind" ];
};

# NFS server
services.nfs.server = {
  enable = true;
  exports = ''
    /export/rw/media  old-machine-ip(rw,sync,no_subtree_check,all_squash,anonuid=1500,anongid=1500)
    /export/ro/media  new-machine-ip(ro,sync,no_subtree_check,all_squash,anonuid=1500,anongid=1500)
  '';
};
```

`all_squash` maps all NFS access to a single UID/GID (1500 here), eliminating permission mismatches between services regardless of which microvm or user initiates the operation.

### NAS Microvm: *arr Stack via virtiofs

```nix
microvm.vms.arr = {
  config = { ... };
  microvm.shares = [
    {
      source = "/data/media";          # ZFS pool mount on NAS host
      mountPoint = "/media";           # Guest sees full RW tree at /media
      tag = "media";
      proto = "virtiofs";
    }
    {
      source = "/persist/microvms/arr"; # btrfs persistent subvolume on NAS host
      mountPoint = "/persist";
      tag = "persist";
      proto = "virtiofs";
    }
  ];
};
```

Persistent state declared via impermanence in the microvm guest:

```nix
environment.persistence."/persist" = {
  directories = [
    "/var/lib/sonarr"
    "/var/lib/radarr"
    "/var/lib/bazarr"
  ];
};
```

Service configuration:

```nix
services.sonarr = { enable = true; group = "media"; };
services.radarr = { enable = true; group = "media"; };
services.bazarr = { enable = true; group = "media"; };

# Deprioritize so arr operations don't starve other NAS workloads
systemd.services.sonarr.serviceConfig = {
  Nice = 19;
  IOSchedulingClass = "idle";
  CPUWeight = 10;
};
systemd.services.radarr.serviceConfig = {
  Nice = 19;
  IOSchedulingClass = "idle";
  CPUWeight = 10;
};
```

### NFS Mount — Old Machine (Read-Write)

```nix
fileSystems."/media" = {
  device = "nas-ip:/export/rw/media";
  fsType = "nfs";
  options = [
    "nfsvers=4.2"
    "hard"
    "noatime"
    "rsize=1048576"
    "wsize=1048576"
    "timeo=600"
    "retrans=2"
    "nofail"
    "_netdev"
    "x-systemd.automount"
    "noauto"
    "x-systemd.idle-timeout=0"
  ];
};
```

### NFS Mount — New Machine (Read-Only)

The RO export binds `/data/media/library` but the new machine mounts it at `/media/library`. This compensates for the narrower bind mount scope, producing paths consistent with what Sonarr and Radarr report — both see `/media/library/...`. See the Path Equivalence section for the full explanation.

```nix
fileSystems."/media/library" = {
  device = "nas-ip:/export/ro/media";
  fsType = "nfs";
  options = [
    "nfsvers=4.2"
    "hard"
    "ro"
    "noatime"
    "rsize=1048576"
    "timeo=600"
    "retrans=2"
    "nofail"
    "_netdev"
    "x-systemd.automount"
    "noauto"
    "x-systemd.idle-timeout=0"
  ];
};
```

### Jellyfin Service (New Machine)

```nix
hardware.graphics = {
  enable = true;
  extraPackages = with pkgs; [
    intel-media-driver
    intel-compute-runtime
  ];
};

users.users.jellyfin.extraGroups = [ "render" "video" ];

services.jellyfin = {
  enable = true;
  group = "media";
  openFirewall = true;
};

systemd.services.jellyfin.environment = {
  DOTNET_SYSTEM_IO_DISABLEFILELOCKING = "true";
};
```

---

## Data Flow Summary

### New Media (Manual Upload)

```
Desktop machine
  → rsync/scp → /data/media/manual/movies/ (NAS host, direct or via RW NFS)
  → Radarr Manual Import (NAS microvm, sees /media/manual/) → reviews match
  → hardlink to /media/library/movies/Movie Name (2024)/ (virtiofs, local kernel op on host)
  → Radarr notifies Jellyfin API (HTTP POST to new machine)
  → Jellyfin targeted scan of /media/library/movies/Movie Name (2024)/ → media appears
```

### New Media (Migration from Old System)

```
Old unorganized library
  → mnamer renames files into /media/manual/ (NAS microvm)
  → Radarr/Sonarr Manual Import → bulk ingest
  → hardlink to /media/library/ (virtiofs, local kernel op on host)
  → Jellyfin API notification → appears in library
```

### Subtitles

```
Radarr/Sonarr import triggers Bazarr (NAS microvm)
  → Bazarr queries subtitle providers
  → writes Movie.en.srt alongside Movie.mkv in /media/library/
  → Jellyfin detects .srt on next scan (or next scheduled scan)
```

### Re-encoding

```
Unmanic (old machine) reads source file from /media/library/ (RW NFS)
  → SVT-AV1 software encode to temp file
  → atomic replace of original on completion
  → Jellyfin detects updated file on next scan
```

### ROM Management

```
ROM files copied to /data/media/library/roms/ps/ (NAS host, direct or via RW NFS)
  → RomM periodic scan detects new files (RO NFS, new machine, sees /media/library/roms/)
  → RomM scrapes IGDB/MobyGames metadata
  → game appears in RomM web UI
  → user launches in browser via EmulatorJS
```

---

## Tool Reference

| Tool | Role | Machine | Source |
|------|------|---------|--------|
| Jellyfin | Video/TV media server | New | jellyfin.org |
| RomM | ROM library & EmulatorJS frontend | New | github.com/rommapp/romm |
| Navidrome | Music streaming (optional) | New | navidrome.org |
| Audiobookshelf | Audiobook & podcast server (optional) | New | audiobookshelf.org |
| Kavita | Ebook, comic & manga library (optional) | New | kavitareader.com |
| Immich | Photo & video backup (optional) | New | immich.app |
| Caddy | Reverse proxy + TLS | New | caddyserver.com |
| Sonarr | TV organization & import | NAS microvm | servarr.com |
| Radarr | Movie organization & import | NAS microvm | servarr.com |
| Bazarr | Subtitle automation | NAS microvm | bazarr.media |
| Lidarr | Music organization (optional) | NAS microvm | servarr.com |
| Recyclarr | Syncs TRaSH Guide quality profiles to *arr | NAS microvm | recyclarr.dev |
| Unmanic | Background AV1 re-encoding | Old | unmanic.app |
| mnamer | One-time bulk media renaming | NAS microvm (run once) | pypi.org/project/mnamer |
| MusicBrainz Picard | Music tag correction (optional) | NAS microvm (run once) | picard.musicbrainz.org |
| Nixarr | NixOS modules for *arr stack | NAS microvm | nixarr.com |

---

## Key Constraints and Gotchas

**Hardlinks require one server-side filesystem.** If your NAS uses separate ZFS datasets for `/data/media/torrents` and `/data/media/library`, hardlinks will silently fall back to copying. Use one dataset (`data/media`) with subdirectories.

**Bind mounts do not cross filesystem boundaries.** A plain `bind` mount of `/data/media` will not include child ZFS datasets. Verify your NAS layout or use `rbind` with care.

**Path equivalence is preserved by compensating mount points, not identical bind mounts.** The RW export binds `/data/media`; the RO export binds `/data/media/library`. The new machine mounts the RO export at `/media/library`, not `/media`, which exactly compensates for the narrower scope. Both machines resolve `/media/library/...` to the same data. This is intentional — do not change the RO mount point to `/media` without also changing the bind mount source.

**inotify does not work on NFS.** Jellyfin's real-time monitoring will silently fail. Use Sonarr/Radarr API notifications as the primary trigger and a scheduled scan as a fallback.

**Jellyfin's SQLite database must be on local storage.** Only media files belong on NFS.

**Bazarr must be co-located with the RW filesystem access.** It writes subtitle files into the organized library. In this architecture it runs on the NAS microvm with virtiofs access.

**PS2 and GameCube are not practically viable for browser-based emulation today.** Plan for native emulation if these platforms matter.

**NFS mounts must use `hard`, not `soft`.** Soft mount timeouts cause Jellyfin to treat media as deleted.

**The RO export is enforced server-side.** Client-side `ro` mount options are a convenience; the NAS export definition is the authoritative security boundary.

**Radarr peak RAM spikes during initial library import.** Temporarily increase the NAS microvm's RAM allocation during first ingestion of a large existing collection. Provision swap as a pressure valve for ongoing steady-state spikes.

**Unmanic needs RW NFS access on the old machine.** The old machine's sole remaining reason for the RW mount is writing re-encoded files back into the library. This is acceptable — it is an internal batch worker, not an externally-facing service.

**AV1 hardware encode is not available on the Meerkat (meer8).** The Alder Lake Xe GPU supports AV1 hardware decode but not encode. SVT-AV1 software encoding on the old machine is the correct approach — it is compute-intensive but not latency-sensitive.

**Microvm guest images should live on the btrfs SSD, not the ZFS HDD pool.** This ensures VM boot, NixOS store access, and *arr stack binary execution never spin up the HDDs. Only deliberate media operations — imports, subtitle writes, encode reads/writes — should touch the spinning disks.
