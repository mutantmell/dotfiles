# Media Ingestion Runbook

Step-by-step guide for ingesting media from the old (`/data/old/`) collection into
the new arr-managed library, end-to-end through the bose → liberl → oracion
pipeline.

## Context recap

```
liberl (NAS host)                          calvard host
├── /data/old/                ←── old collection sitting on root dataset
├── /data/media/              ←── ZFS dataset, single fs (hardlink scope)
│   ├── manual/{movies,tv,music}/    ←── DROP ZONE for ingestion
│   ├── torrents/{...}/              ←── future download client output
│   ├── usenet/complete/{...}/       ←── future download client output
│   └── library/{movies,tv,music}/   ←── arr-managed organized library
│        │                                │
│        └── virtiofs to bose ──┐         │
│        └── NFS RO ────────────┼────► oracion guest (Jellyfin)
│                               │       /media/library/
│        bose guest (arr stack) │
│        /media → /data/media   │
│        Sonarr 8989, Radarr 7878,
│        Bazarr 6767
```

Key paths:

- **Drop zone (NAS host):** `/data/media/manual/{movies,tv,music}/`
- **Same paths inside bose:** `/media/manual/{movies,tv,music}/`
- **Library inside bose (virtiofs):** `/media/library/{movies,tv,music}/`
- **Library inside oracion (RO NFS):** `/media/library/{movies,tv,music}/`
- **Old collection on liberl:** `/data/old/` (root dataset, plain dirs)

All ingestion goes drop-zone → arr Manual Import (which **hardlinks** into
`library/`) → Connect notification → Jellyfin scan.

## Phase 0: Pre-flight

Run these once before starting. Catch issues now, not halfway through a 2 TB
copy.

### 0.1 — Confirm services are healthy

On liberl:

```bash
systemctl status microvm@bose
systemctl status nfs-server
zpool status data
zfs list -r data
ls /data/old/                                # should show the old collection
ls /data/media/manual/{movies,tv,music}      # should exist, owned 400:400, mode 2775
ls /data/media/library/{movies,tv,music}     # should exist, owned 400:400, mode 2775
stat -c '%a %u:%g %n' /data/media /data/media/manual /data/media/library
```

The `manual/` and `library/` subdirs are created and enforced declaratively
by `systemd.tmpfiles.rules` in `hosts/liberl/nas.nix` (mode `2775`,
owner/group `media:media`). If anything looks off (wrong mode, wrong owner,
missing subdir), trigger a re-apply rather than fixing by hand:

```bash
systemd-tmpfiles --create
```

The `2775` mode = setgid + group-writable, so the arr stack (sonarr/radarr
run as their own user with `group=media`) can write into the tree, and any
new subdir created by a non-media user still inherits `group=media`.

### 0.2 — Confirm bose can see the media tree

```bash
ssh root@bose.internal
ls -la /media/                               # manual, library, torrents, usenet, ...
stat -c '%a %u:%g' /media/manual             # 2775 400:400 (setgid, media uid:gid)
stat -f -c '%T' /media                       # fuseblk / virtiofs — single namespace
```

Sanity-check hardlink across the same dataset:

```bash
touch /media/manual/movies/.hltest
ln /media/manual/movies/.hltest /media/library/movies/.hltest
ls -li /media/manual/movies/.hltest /media/library/movies/.hltest
# Both lines must show the same inode and link count 2.
rm /media/manual/movies/.hltest /media/library/movies/.hltest
```

If `ln` fails with `EXDEV`, you have nested datasets — stop and fix the ZFS
layout before going further (the spec requires `data/media` to be a single
dataset with no children).

### 0.3 — Confirm bose can reach oracion (for Jellyfin Connect)

```bash
ssh root@bose.internal
curl -sk https://oracion.internal:443/ -o /dev/null -w '%{http_code}\n'   # nginx, 200/301
curl -sk http://oracion.internal:8096/ -o /dev/null -w '%{http_code}\n'    # jellyfin, 302
```

If the second curl fails, the egress rule for `oracion:8096` in
`hosts/liberl/microvm/guests/bose/default.nix` is doing its job — verify it's
present and the rule was deployed.

### 0.4 — Confirm bose can reach Servarr metadata endpoints

Library Import is dead in the water without TMDB metadata, which Radarr
(and Sonarr) fetch through Servarr's SkyHook proxy. From bose:

```bash
ssh root@bose.internal
getent hosts skyhook.sonarr.tv api.themoviedb.org services.radarr.tv
curl -sv --max-time 8 https://skyhook.sonarr.tv/v1/ping  -o /dev/null 2>&1 | tail -5
curl -sv --max-time 8 https://api.themoviedb.org/3/configuration -o /dev/null 2>&1 | tail -5
```

DNS must resolve all three names. The `curl` calls must reach a real HTTP
response (any status — `404`, `200`, `401` are all fine; what you're
checking is that the TLS handshake completes and a response header comes
back). A bare timeout or `Could not resolve host` means egress or DNS is
broken — the egress allowlist in
`hosts/liberl/microvm/guests/bose/default.nix` should cover this with the
`any host, tcp/443` rule, but verify the rule is present and deployed.

### 0.5 — Confirm calvard NFS mount is healthy (for Jellyfin)

From oracion:

```bash
ssh root@oracion.internal
mountpoint /media
findmnt /media                               # liberl.internal:/export/ro/media, ro,hard
ls /media/library                            # should mirror what bose sees
touch /media/library/.rotest 2>&1            # MUST fail with "Read-only file system"
```

## Phase 1: First-time arr stack configuration

You only do this once. After this, ingestion is just dropping files and
clicking Manual Import.

### 1.1 — Reach the web UIs

bose is on VLAN 21 (lab) at `bose.internal` (10.97.21.43). From any host with
lab access (edith, or anything on trusted that can route to lab):

- Sonarr: `http://bose.internal:8989`
- Radarr: `http://bose.internal:7878`
- Bazarr: `http://bose.internal:6767`

If you need access from a workstation on the trusted VLAN that can't route
directly:

```bash
ssh -L 8989:bose.internal:8989 -L 7878:bose.internal:7878 -L 6767:bose.internal:6767 root@edith.internal
# Then open http://localhost:8989 etc.
```

### 1.2 — Sonarr first-run

1. **Authentication.** Pick **Forms (Login Page)**, set a username and a
   strong password. Authentication Required: **Enabled**.
2. **Settings → Media Management → File Management:**
   - Use Hardlinks instead of Copy: **ON**
   - Import Extra Files: **ON** (`srt,sub,nfo`)
   - Set Permissions: **ON**
   - chmod Folder: `755`, chmod File: `644`
   - chown User: `media`, chown Group: `media`
3. **Settings → Media Management → Episode Naming:**
   - Rename Episodes: **ON**
   - Use the recommended TRaSH naming token, e.g.:
     - Standard Episode Format: `{Series TitleYear} - S{season:00}E{episode:00} - {Episode CleanTitle} [{Quality Title}]{[Mediainfo VideoDynamicRangeType]}{[Mediainfo VideoBitDepth]bit}{[Mediainfo VideoCodec]}{[Mediainfo AudioCodec}{ Mediainfo AudioChannels]}{[Mediainfo AudioLanguages]}{[MediaInfo SubtitleLanguages]}-{Release Group}`
     - Series Folder Format: `{Series TitleYear}`
     - Season Folder Format: `Season {season:00}`
4. **Settings → Media Management → Folders:**
   - Create empty series folders: **OFF**
   - Delete empty folders: **ON**
5. **Add Root Folder** (Settings → Media Management → Root Folders, or
   when adding a series): `/media/library/tv`
6. **Settings → Profiles → Quality Profiles:** start with stock profiles,
   tune later. Recyclarr can sync TRaSH guides — out of scope here.
7. **Settings → Indexers / Download Clients:** **leave empty for now.** This
   migration is Manual Import only; download clients come later when you set
   up indexers.
8. **Settings → General → Security:** record the **API Key** — you'll need it
   in Bazarr.

### 1.3 — Radarr first-run

Same shape as Sonarr, with movie-flavored differences:

1. Authentication: Forms, password, Required.
2. **Settings → Media Management → File Management:**
   - Use Hardlinks instead of Copy: **ON**
   - Import Extra Files: **ON** (`srt,sub,nfo`)
   - Set Permissions: **ON**, chmod 755/644, chown `media:media`
3. **Settings → Media Management → Movie Naming:**
   - Rename Movies: **ON**
   - Standard Movie Format (TRaSH): `{Movie CleanTitle} ({Release Year}) {edition-{Edition Tags}} [{Custom Formats}]{[Quality Full]}{[MediaInfo 3D]}{[MediaInfo VideoDynamicRangeType]}[{Mediainfo VideoBitDepth}bit]{[Mediainfo VideoCodec]}{-Release Group}`
   - Movie Folder Format: `{Movie CleanTitle} ({Release Year})`
4. **Add Root Folder:** `/media/library/movies`
5. **Indexers / Download Clients:** leave empty.
6. **Settings → General:** record the **API Key**.

### 1.4 — Jellyfin API key (on oracion)

Before configuring Connect on Sonarr/Radarr, generate a Jellyfin API key:

1. Browse `https://oracion.internal/` (or whatever DNS / reverse proxy you
   use).
2. **Dashboard → API Keys → +** (top right). Name it `arr-stack`.
3. Copy the key.

### 1.5 — Wire Sonarr/Radarr → Jellyfin (Connect)

In **Sonarr** Settings → Connect → **+ → Emby Server** (Jellyfin shares the
plugin):

- Name: `Jellyfin`
- Host: `oracion.internal` (or its IP `10.97.100.52`)
- Port: `8096`
- API Key: paste the Jellyfin key
- Use SSL: **OFF** (HTTP on port 8096 inside the network)
- Update Library: **ON**
- Send Notifications: **OFF** (broken in modern Jellyfin)
- On Import, On Upgrade, On Rename: **ON**
- Click **Test** — must succeed before saving.

Repeat in **Radarr** with the same settings (the per-event triggers are
named slightly differently — turn on the Import/Upgrade/Rename ones).

### 1.6 — Bazarr first-run

1. Authentication: Forms, password, Required.
2. **Settings → Sonarr:**
   - Address: `bose.internal` (or `127.0.0.1`)
   - Port: `8989`
   - API Key: Sonarr's API key from 1.2
   - Click **Test** → green.
3. **Settings → Radarr:**
   - Address: `bose.internal` (or `127.0.0.1`)
   - Port: `7878`
   - API Key: Radarr's API key from 1.3
   - Test → green.
4. **Settings → Languages:**
   - Enabled Languages: pick your wanted language(s), e.g. English.
   - Create a **Language Profile** with the wanted languages, set as default
     for both Sonarr and Radarr (Settings → Sonarr / Radarr → Default
     settings).
5. **Settings → Providers:**
   - **OpenSubtitles.com** (free account at opensubtitles.com — note: the
     newer `.com` provider, not the legacy `.org` one) is a sensible default.
   - **Addic7ed** for TV.
   - Avoid enabling everything; rate limits will start tripping.
6. **Settings → Subtitles:**
   - Use embedded subtitles: **ON**
   - Upgrade previously downloaded subtitles: **ON**
   - Enable hearing-impaired subtitles: per taste.

## Phase 2: Where files go for ingestion

There is exactly **one** drop zone, with three subdirectories:

```
/data/media/manual/movies/
/data/media/manual/tv/
/data/media/manual/music/
```

This is the same directory whether you stage from the liberl host shell, the
bose guest, an SMB share, or rsync over SSH — they all converge on the same
inode tree (the `data/media` ZFS dataset). The arr stack picks files up from
here, hardlinks them into `library/`, and (with Connect) pings Jellyfin.

Three ways to put files into the drop zone:

### 2.1 — From liberl itself (move from /data/old/)

Fastest for the migration: `/data/old/` is on the same ZFS pool but a
**different dataset** (the root dataset), so a `mv` will fall back to copy.
Use rsync to preserve attrs and remove sources, then verify and clean up.

```bash
ssh root@liberl

# Movies
rsync -aHAX --info=progress2 --remove-source-files \
  /data/old/media/movies/ /data/media/manual/movies/

# TV
rsync -aHAX --info=progress2 --remove-source-files \
  /data/old/media/tv/ /data/media/manual/tv/

# Music
rsync -aHAX --info=progress2 --remove-source-files \
  /data/old/media/music/ /data/media/manual/music/

# Fix ownership and mode for the arr stack. rsync preserves the source
# uid/gid/mode, which won't match what the arr stack expects.
chown -R 400:400 /data/media/manual
find /data/media/manual -type d -exec chmod 2775 {} +
find /data/media/manual -type f -exec chmod 664  {} +

# Clean up empty directories left by --remove-source-files
find /data/old/media -type d -empty -delete
```

**Do this in batches.** A single `rsync` of the whole movies tree is fine for
files; the issue is Radarr's RAM usage scales with how many it sees in
manual import. Stage 50–200 movie folders, import, watch RAM, repeat. (The
guest has 8 GB RAM + zramSwap as a safety valve, but bulk imports of large
collections are the documented worst case.)

### 2.2 — From a desktop via SMB

Liberl exposes the media share over SMB to the trusted VLAN:

- Share: `\\LIBERL\media`
- User: your Samba user (configured separately)
- Drop into: `\\LIBERL\media\manual\movies\` (etc.)

After uploading, run on liberl to fix permissions:

```bash
chown -R 400:400 /data/media/manual
find /data/media/manual -type d -exec chmod 2775 {} +
find /data/media/manual -type f -exec chmod 664  {} +
```

(Samba writes files as the SMB user. New *directories* under `manual/`
inherit `group=media` from the setgid bit, but the *uid* will be the SMB
user's, and *files* keep the SMB user's umask — so a `chown` and a mode
sweep is still required after a batch upload. Or set `force user = media`
/ `force group = media` on the share if this becomes routine.)

### 2.3 — From a desktop via rsync/scp

```bash
rsync -aHAX --info=progress2 \
  ./local-pile/ \
  root@liberl.internal:/data/media/manual/movies/

ssh root@liberl '
  chown -R 400:400 /data/media/manual
  find /data/media/manual -type d -exec chmod 2775 {} +
  find /data/media/manual -type f -exec chmod 664  {} +
'
```

## Phase 3: Required — pre-rename with mnamer

This is **not optional** for a bulk migration. Radarr's Library Import scans
for *per-movie subdirectories* shaped like `Movie Title (Year)/file.ext`,
not loose files in the folder root. A `manual/movies/` directory full of
loose `.mkv` files will produce the misleading message **"All movies in
/media/manual/movies have been imported"** — the empty-state shown when
zero movie-shaped subdirectories were found, *not* a confirmation that
anything was actually imported. Sonarr's Library Import has the same
shape requirement for `Series Title (Year)/Season NN/...`.

mnamer's job here is to do two things in one pass:

1. **Rename** files to a parseable `Title (Year).ext` (Radarr's parser
   needs both title and year — a year-less filename like `Big Hero 6.mkv`
   will not match any TMDB entry on its own).
2. **Nest** each file into a `Title (Year)/` subdirectory, which is what
   Library Import actually scans for.

The format string below does both jobs.

### What mnamer owns vs. what Radarr owns

mnamer normalizes names **inside `/media/manual/`** only. It does not write
to `/media/library/`. The boundary is intentional:

- `manual/` is mnamer's domain — coarse "make this parseable" naming.
- `library/` is **Radarr's domain** — Radarr writes here via hardlink
  during Library Import, applying the canonical TRaSH naming scheme from
  §1.3 (which embeds quality/codec/HDR/audio/release-group, things mnamer
  doesn't know).

If you bypass Radarr and `mv` files directly into `library/`, you defeat
the whole pipeline: Radarr won't track them in its DB, won't fire Connect
to Jellyfin on changes, and Bazarr won't see them. Always: drop in
`manual/` → mnamer normalize → Radarr Library Import → `library/`.

### Running mnamer

mnamer is provided as a system package on bose (via `arr.nix`), so it's
on `$PATH` directly — no `nix-shell` needed.

```bash
ssh root@bose.internal

# Movies — dry run first
mnamer --movie-directory=/media/manual/movies \
       --movie-format='{name} ({year})/{name} ({year}).{extension}' \
       --test \
       /media/manual/movies/

# Real run
mnamer --movie-directory=/media/manual/movies \
       --movie-format='{name} ({year})/{name} ({year}).{extension}' \
       /media/manual/movies/

# TV
mnamer --episode-directory=/media/manual/tv \
       --episode-format='{series} ({year})/Season {season:02}/{series} - S{season:02}E{episode:02} - {title}.{extension}' \
       --test \
       /media/manual/tv/
```

mnamer organizes in place under `/media/manual/`. After it runs, each
movie sits in its own `Title (Year)/` directory — exactly what Library
Import expects. Radarr will then re-organize and hardlink into
`/media/library/` during the import step.

### When mnamer can't identify a file

mnamer needs *some* signal in the original filename — a real title, ideally
a year — to do TMDB lookups. For genuinely opaque names (`movie01.mkv`,
`disc1.mkv`), it'll fail too. Two fallbacks:

- **FileBot** — stronger heuristics than mnamer, including hash-based
  matching against OpenSubtitles / AcoustID / TheTVDB. It can identify a
  movie even from `disc1.mkv` if the file's hash is in the database. Not
  in nixpkgs (proprietary, paid for current versions); available as
  AppImage. Worth running once over a really messy library.
- **Hand-rename the holdouts.** For the few survivors after mnamer +
  FileBot, just `mv` them into `Title (Year)/Title (Year).ext` by hand.
  After mnamer, the residual count is usually small.

## Phase 4: The actual ingestion (per-app workflow)

### 4.1 — Radarr Manual Import (movies)

**Prerequisite:** Phase 3 must be complete. Each movie under
`/media/manual/movies/` should sit in its own `Title (Year)/` subdirectory.
If you skipped Phase 3, the Library Import wizard will say "All movies in
/media/manual/movies have been imported" and show nothing — see
Troubleshooting.

1. Sidebar → **Movies** → **Library Import** (top button, also reachable
   from Add New → Import Movies; URL is `/add/import`).
2. Folder: `/media/manual/movies` — **not** `/media/library/movies`,
   which is empty until Radarr writes into it.
3. Radarr scans subdirectories and shows matched movies. Inspect:
   - Each row has the matched TMDB title, monitored status, quality profile,
     root folder.
   - **Set Quality Profile** and **Root Folder** in the bulk-edit bar at the
     top — `/media/library/movies` is the only root folder, so it should
     auto-select.
   - Verify each match is correct. Manually fix wrong matches by clicking
     the title and searching TMDB.
4. Select all → **Import** (top right).
5. Radarr hardlinks the file into
   `/media/library/movies/{Movie Title (Year)}/...`. The original stays in
   `manual/` (it's a hardlink, not a move).
6. Connect fires → Jellyfin runs a targeted scan.

**Verify a hardlink was actually created** (not a copy):

```bash
ssh root@bose.internal
ls -li /media/manual/movies/Foo/Foo.mkv \
       /media/library/movies/'Foo (2024)'/'Foo (2024).mkv'
# Both rows: same inode number, link count 2.
```

If they have **different** inodes, hardlinking failed (likely EXDEV) — stop
and diagnose before importing more.

### 4.2 — Sonarr Manual Import (TV)

1. Sidebar → **Series** → **Import** (top button).
2. Folder: `/media/manual/tv`
3. Sonarr scans for series and lists each detected show.
4. For each show, set **Monitor**, **Quality Profile**, **Series Type**
   (Standard/Daily/Anime), and **Root Folder** = `/media/library/tv`.
5. Select all → **Import**.
6. Sonarr hardlinks each episode into the renamed series/season layout.

For lone episodes (not full seasons in their own folders), Sonarr may want
you to use **Wanted → Manual Import** instead, pointed at
`/media/manual/tv`, which lets you cherry-pick individual files.

### 4.3 — Cleanup after each batch

After Radarr/Sonarr report a successful import:

```bash
ssh root@liberl

# manual/ files are now hardlinks; deleting them just unlinks the staging
# pointer — the library file remains. Confirm link count drops to 1 in
# library/ after this.
find /data/media/manual/movies -type f -delete
find /data/media/manual/movies -type d -empty -delete

# Repeat for tv, music as appropriate.
```

You don't *have* to clean up — leaving the second hardlink costs nothing
storage-wise. But the staging area gets noisy if you don't.

### 4.4 — Bazarr backfill

Once a batch is in `library/`, Bazarr will pick it up automatically (it
polls Sonarr/Radarr). To force a sweep:

- Bazarr → **Series** / **Movies** → select all → **Mass Edit** → set
  Language Profile / Subtitles → Save.
- Or: **System → Tasks** → run **Sync with Sonarr** / **Sync with Radarr**
  manually.

## Phase 5: Verifying Jellyfin sees the imports

1. Jellyfin should auto-update via Connect within seconds of an import. If
   it doesn't:
   - Dashboard → Logs — look for the API call from bose.
   - Dashboard → Scheduled Tasks → run **Scan Media Library** manually.
2. **Set up the scheduled fallback** (do once): Dashboard → Scheduled Tasks
   → Scan Media Library → set to run every 4 hours. inotify doesn't work
   over NFS, so this is your safety net for any Connect failure.
3. **Library configuration** (do once, if not already):
   - Dashboard → Libraries → Add Media Library
   - **Movies** library, folder `/media/library/movies`
   - **TV Shows** library, folder `/media/library/tv`
   - **Music** library, folder `/media/library/music`
   - Real-time monitoring: **OFF** (no inotify on NFS).

## Phase 6: When the ingestion is done

1. Verify everything you wanted is in `/data/media/library/`. Compare
   against an inventory of `/data/old/media/` (if it still exists).
2. Once satisfied, retire `/data/old/`:

   ```bash
   du -sh /data/old/
   # If you're SURE everything's been ingested:
   rm -rf /data/old/media
   # Triage the rest of /data/old/ separately.
   ```

3. **Snapshot the library** before further bulk operations:

   ```bash
   zfs snapshot data/media@post-ingestion-$(date +%Y%m%d)
   ```

4. Future ingestion is the same workflow without the old-collection rsync:
   drop new files into `/data/media/manual/{movies,tv,music}/`, Manual
   Import in Radarr/Sonarr.

## Troubleshooting

**Library Import says "All movies in /media/manual/movies have been
imported" but the Movies page is empty.** This is the runbook's most
common confusing failure. The message is a vacuously-true empty state,
*not* an import confirmation. Two causes, in order of likelihood:

1. **Files aren't in per-movie subdirectories.** Library Import scans for
   `Title (Year)/` subfolders. Loose files in the folder root are
   invisible to it. Confirm:
   ```bash
   ssh root@bose.internal
   ls /media/manual/movies/        # should be subdirectories, not .mkv files
   ```
   Fix by running Phase 3 (mnamer with the folder-creating format string).
   To smoke-test before re-running mnamer over the whole tree, hand-create
   one folder:
   ```bash
   ssh root@liberl
   cd /data/media/manual/movies
   mkdir -p 'Some Movie (2024)' && mv 'Some Movie (2024).mkv' 'Some Movie (2024)/'
   chown -R 400:400 'Some Movie (2024)'
   ```
   Re-run Library Import. If that one row appears, structure was the issue.

2. **You typed the wrong folder.** `/media/library/movies` is empty until
   Radarr writes into it; `/media/manual/movies` is the source. Easy to
   transpose. Re-check the folder field in the Library Import wizard.

**Movies page shows "No movies found, to get started you'll want to add
a new movie or import some existing ones."** This is Radarr's default
empty-state for the Movies page when its DB has no movie records — it is
not a sign that an import failed. To run an import you have to navigate
to the **Library Import** page (`/add/import`, or Movies sidebar →
Library Import button at the top, or Add New → Import Movies tile).
Filters at the top of the Movies page (Monitored / Missing / etc.) can
also hide entries that *do* exist; switch to "All" to rule that out.

**Radarr logs show `SkyHookProxy.GetTrendingMovies` or
`UpdatePackageProvider.GetLatestUpdate` timeouts.** Both are outbound
HTTPS calls. A handful at boot is normal — bose's network or the gateway
isn't fully up yet when Radarr fires its first health-check sweep. The
test is whether they recur during normal operation: re-run the curls
from §0.4. If those succeed, the boot-time errors are cosmetic. If they
fail, the egress allowlist or upstream DNS/NAT is the problem (see §0.4).

**Hardlink fails with EXDEV.** `manual/` and `library/` are on different
filesystems. They must both live under the same single ZFS dataset
(`data/media`). Verify with `zfs list -r data/media` — must show exactly
one row. If there are children, they need to be merged.

**Permission errors during import.** The arr services run as their service
user but with `group = "media"` (gid 400). Files in `manual/` must be group
`400` and group-readable; directories must additionally be group-writable
(mode `2775`) so arr can hardlink/move into and out of them. The library
tree is enforced at `2775` by `systemd.tmpfiles.rules` in
`hosts/liberl/nas.nix` — but external writers (SMB, scp, rsync from
elsewhere) can introduce files with the wrong owner or mode. After any
non-arr write into `manual/`:

```bash
chown -R 400:400 /data/media/manual
find /data/media/manual -type d -exec chmod 2775 {} +
find /data/media/manual -type f -exec chmod 664  {} +
```

If even `library/` itself looks wrong (e.g. someone manually `mkdir`'d a
subdir without setgid), re-apply tmpfiles: `systemd-tmpfiles --create`.

**Radarr OOM during bulk import.** bose has 8 GB + zramSwap. If Radarr
still OOMs, work in smaller batches (≤200 movies at a time), or temporarily
bump `microvm.mem` in `hosts/liberl/microvm/guests/bose/microvm.nix` to
16384 just for the migration, then drop it back.

**Jellyfin doesn't update after an import.** Check in order:
1. Sonarr/Radarr → Settings → Connect → Test the Jellyfin connection.
2. From bose: `curl -v http://oracion.internal:8096/` — should be 302. If
   not, the egress filter or the lab→dmz forward rule is the issue.
3. On oracion: `journalctl -u jellyfin -n 100` — look for incoming API
   calls.
4. Trigger a manual scan via Dashboard → Scheduled Tasks.

**`/media/library/` looks wrong from oracion's side but right from bose.**
The NFS RO mount on oracion (or calvard) is stale. From oracion:
`umount /media; ls /media` (the automount will remount it). Or restart the
microvm.

**arr stack runs but virtiofs `/media` is empty inside bose.** Check that
`/data/media` exists on liberl and contains the staging tree. virtiofs
shows whatever the host has at the time of the share — restart
`microvm@bose` after host-side mount changes.

**SMB-uploaded files have wrong owner/group.** Samba writes as the SMB
user, not as `media`. After each batch upload run the chown + chmod sweep
from "Permission errors during import" above, or set
`force user = media` / `force group = media` on the share if this becomes
routine.

## Reference: which path means what

| Where you are            | Drop / staging           | Library                        |
| ------------------------ | ------------------------ | ------------------------------ |
| liberl host              | `/data/media/manual/...` | `/data/media/library/...`      |
| bose guest (virtiofs)    | `/media/manual/...`      | `/media/library/...`           |
| oracion guest (NFS RO)   | _(not visible)_          | `/media/library/...`           |
| Desktop via SMB          | `\\LIBERL\media\manual\` | _(visible, but don't write)_   |

The asymmetric visibility on oracion is the security boundary: Jellyfin
literally cannot see the staging directories.
