# Media Ingestion Runbook

Step-by-step guide for ingesting media from the old (`/data/old/`) collection into
the new arr-managed library, end-to-end through the bose+ravennue → liberl →
oracion pipeline.

## Context recap

The arr stack is **split across two microVMs by quality tier** so multiple
encodings of the same title can coexist (Radarr/Sonarr each track exactly
one file per record):

- **bose** — HQ tier arrs (Sonarr, Radarr) + Bazarr. Root folders:
  `/media/library-hq/{movies,tv}`. Quality profiles **2160p-only** (video).
- **ravennue** — Default tier arrs (Sonarr, Radarr). Root folders:
  `/media/library/{movies,tv}`. Quality profiles **≤1080p only** (video).

The tier split is done at the **library level** (`library/` vs `library-hq/`)
rather than as a `-hq` suffix inside a single tree. This keeps the
ownership boundary unambiguous — each Sonarr/Radarr instance owns one
top-level dir and never traverses the other — and leaves room for future
curated/derived trees per tier without colliding with the suffix. The
name `-hq` (rather than `-4k`) generalizes the tier across video and
audio (lossless) without ever needing another rename.

```
liberl (NAS host)                          calvard host
├── /data/old/                  ←── old collection sitting on root dataset
├── /data/media/                ←── ZFS dataset, single fs (hardlink scope)
│   ├── staging/manual/{movies,tv,music}/  ←── DROP ZONE — default tier (→ ravennue)
│   ├── staging/manual/{console,romhacks,pc}/  ←── games staging — default tier
│   ├── staging-hq/manual/{movies,tv}/    ←── DROP ZONE — HQ tier   (→ bose)
│   ├── library/{movies,tv,music}/        ←── arr-managed library — default tier
│   ├── library/{console,romhacks,pc}/    ←── games library (Igir/operator-managed)
│   └── library-hq/{movies,tv}/           ←── arr-managed library — HQ tier
│        │                                 │
│        └── virtiofs → bose, ravennue ───┐
│        └── NFS RO ──────────────────────┼──► oracion guest (Jellyfin + Retrom)
│                                         │    /media/{library,library-hq}/
│        bose guest (HQ tier arrs + Bazarr) │
│        /media → /data/media             │
│        Sonarr 8989, Radarr 7878,        │
│        Bazarr 6767                      │
│                                         │
│        ravennue guest (SD/1080p arrs)
│        /media → /data/media
│        Sonarr 8989, Radarr 7878
```

Key paths:

- **Staging zones (NAS host):**
  - `/data/media/staging/manual/{movies,tv,music}/` — default tier (→ ravennue)
  - `/data/media/staging-hq/manual/{movies,tv}/` — HQ tier (→ bose)
  - `/data/media/staging/manual/{console,romhacks,pc}/` — games staging
  - Tier-sort at drop time; the parent dir is the tier signal.
- **Same paths inside bose / ravennue:** `/media/staging/manual/...` and
  `/media/staging-hq/manual/...` (both guests see every staging tree via
  virtiofs; each only operates on its own tier).
- **Libraries inside bose:** `/media/library-hq/{movies,tv}/`
- **Libraries inside ravennue:** `/media/library/{movies,tv}/`
- **Libraries inside oracion (RO NFS):** `/media/library/...` and
  `/media/library-hq/...` (both tiers, read-only).
- **Old collection on liberl:** `/data/old/` (root dataset, plain dirs)

All ingestion goes staging (tier-sorted) → FileBot (writes into the matching
tier's `library*/` subdir) → arr Library Import on the matching instance
(adopt-in-place) → Mass Edit Rename → Connect notification → Jellyfin scan.

## Phase 0: Pre-flight

Run these once before starting. Catch issues now, not halfway through a 2 TB
copy.

### 0.1 — Confirm services are healthy

On liberl:

```bash
systemctl status microvm@bose microvm@ravennue
systemctl status nfs-server
zpool status data
zfs list -r data
ls /data/old/                                                    # should show the old collection
ls /data/media/staging/manual/{movies,tv,music}                  # default-tier staging — all should exist, owned 400:400, mode 2775
ls /data/media/staging-hq/manual/{movies,tv}                     # HQ-tier staging
ls /data/media/library/{movies,tv,music} /data/media/library/tv-curated  # default-tier library + Jellyfin-facing curated TV
ls /data/media/library-hq/{movies,tv}                            # HQ-tier library
stat -c '%a %u:%g %n' /data/media /data/media/{staging,staging-hq,library,library-hq}
```

The `staging*/` and `library*/` subdirs are created and enforced declaratively
by `systemd.tmpfiles.rules` in `hosts/liberl/nas.nix` (mode `2775`,
owner/group `media:media`). If anything looks off (wrong mode, wrong owner,
missing subdir), trigger a re-apply rather than fixing by hand:

```bash
systemd-tmpfiles --create
```

The `2775` mode = setgid + group-writable, so the arr stack (sonarr/radarr
run as their own user with `group=media`) can write into the tree, and any
new subdir created by a non-media user still inherits `group=media`.

### 0.2 — Confirm both arr guests can see the media tree

Run the same checks on **bose** and **ravennue** — they share the same
virtiofs of `/data/media`, but each independently mounts it:

```bash
for guest in bose ravennue; do
  ssh root@$guest.internal -- bash <<'EOF'
    ls -la /media/                               # staging, staging-hq, library, library-hq, ...
    stat -c '%a %u:%g' /media/staging/manual /media/staging-hq/manual   # 2775 400:400 (setgid, media uid:gid)
    stat -f -c '%T' /media                       # fuseblk / virtiofs — single namespace
EOF
done
```

Sanity-check hardlink across the same dataset (run on bose; ravennue
sees the same inodes):

```bash
ssh root@bose.internal
touch /media/staging/manual/movies/.hltest
ln /media/staging/manual/movies/.hltest /media/library/movies/.hltest
ln /media/staging/manual/movies/.hltest /media/library-hq/movies/.hltest
ls -li /media/staging/manual/movies/.hltest /media/library/movies/.hltest /media/library-hq/movies/.hltest
# All three lines must show the same inode and link count 3 — confirms
# `library/` and `library-hq/` are siblings inside the same dataset and
# hardlinks span both tiers.
rm /media/staging/manual/movies/.hltest /media/library/movies/.hltest /media/library-hq/movies/.hltest
```

If `ln` fails with `EXDEV`, you have nested datasets — stop and fix the ZFS
layout before going further (the spec requires `data/media` to be a single
dataset with no children).

### 0.3 — Confirm both guests can reach oracion (for Jellyfin Connect)

```bash
for guest in bose ravennue; do
  echo "== $guest =="
  ssh root@$guest.internal -- bash -c '
    curl -sk https://oracion.internal:443/ -o /dev/null -w "%{http_code}\n"   # nginx, 200/301
    curl -sk http://oracion.internal:8096/ -o /dev/null -w "%{http_code}\n"   # jellyfin, 302
  '
done
```

If the second curl fails, the egress rule for `oracion:8096` in the
guest's `default.nix` is doing its job — verify it's present and the
rule was deployed.

### 0.4 — Confirm both guests can reach Servarr metadata endpoints

Library Import is dead in the water without TMDB metadata, which Radarr
(and Sonarr) fetch through Servarr's SkyHook proxy. From each guest:

```bash
for guest in bose ravennue; do
  echo "== $guest =="
  ssh root@$guest.internal -- bash -c '
    getent hosts skyhook.sonarr.tv api.themoviedb.org services.radarr.tv
    curl -sv --max-time 8 https://skyhook.sonarr.tv/v1/ping  -o /dev/null 2>&1 | tail -5
    curl -sv --max-time 8 https://api.themoviedb.org/3/configuration -o /dev/null 2>&1 | tail -5
  '
done
```

DNS must resolve all three names. The `curl` calls must reach a real HTTP
response (any status — `404`, `200`, `401` are all fine; what you're
checking is that the TLS handshake completes and a response header comes
back). A bare timeout or `Could not resolve host` means egress or DNS is
broken — the egress allowlist in the guest's `default.nix` should cover
this with the `any host, tcp/443` rule, but verify the rule is present
and deployed.

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

Both arr guests are on VLAN 21 (lab):

- **bose** at `bose.internal` (10.97.21.43) — HQ tier instance:
  - Sonarr: `http://bose.internal:8989`
  - Radarr: `http://bose.internal:7878`
  - Bazarr: `http://bose.internal:6767`
- **ravennue** at `ravennue.internal` (10.97.21.44) — Default tier instance:
  - Sonarr: `http://ravennue.internal:8989`
  - Radarr: `http://ravennue.internal:7878`

From any host with lab access (edith, or anything on trusted that can
route to lab) the URLs above work directly. From a workstation on the
trusted VLAN that can't route directly:

```bash
ssh -L 18989:bose.internal:8989     -L 17878:bose.internal:7878 \
    -L 16767:bose.internal:6767 \
    -L 28989:ravennue.internal:8989 -L 27878:ravennue.internal:7878 \
    root@edith.internal
# Then open http://localhost:18989 (bose Sonarr), :17878 (bose Radarr),
# :16767 (Bazarr), :28989 (ravennue Sonarr), :27878 (ravennue Radarr).
```

### 1.2 — Sonarr first-run (do on **both** bose and ravennue)

The configuration below is identical between the two instances **except
for the root folder and the quality profile**, called out at the end.

1. **Authentication.** Pick **Forms (Login Page)**, set a username and a
   strong password. Authentication Required: **Enabled**.
2. **Settings → Media Management → File Management:**
   - Use Hardlinks instead of Copy: **ON**
   - Import Extra Files: **ON** (`srt,sub,nfo`)
   - Analyze video files: **ON** — required so MediaInfo tokens
     (`{Mediainfo VideoCodec}` etc.) populate during Rename Files.
     Without it, Sonarr falls back to filename guessing, which the
     pre-rename tool's scaffold filenames don't carry.
   - Set Permissions: **OFF** — the filesystem layer already enforces
     the right modes (`filebot-ingest`'s `umask 0002` + the setgid 2775
     parents from `nas.nix`). With Set Permissions ON, Sonarr's
     `chown()` and `chmod()` after rename fail with EPERM: FileBot
     creates files owned by the operator's user (not `media`),
     `rename(2)` preserves owner, and Sonarr-as-`media` can't chown
     to a different uid (no CAP_CHOWN) or chmod a file it doesn't
     own. The previously-recommended `chmod 755/644` would also
     strip group-write, re-breaking the next rename.
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
   when adding a series) — **per-instance**:
   - **bose**: `/media/library-hq/tv`
   - **ravennue**: `/media/library/tv`
6. **Settings → Profiles → Quality Profiles** — **per-instance, lock
   the tier**:
   - **bose**: build a profile named e.g. `2160p` that includes only
     the 2160p qualities (`Bluray-2160p`, `WEBDL-2160p`, `WEBRip-2160p`,
     `Remux-2160p`) and **excludes everything below 2160p**.
   - **ravennue**: build a profile named e.g. `≤1080p` that includes
     SD / 720p / 1080p qualities and **excludes 2160p variants**.

   Quality-tier locking is what enforces the split when download clients
   eventually ship: bose can never grab a 1080p release, ravennue can
   never grab a 2160p release, even if an indexer offers both. Recyclarr
   can sync TRaSH guides — out of scope here.

7. **Settings → Indexers / Download Clients:** **leave empty for now.** This
   migration is Manual Import only; download clients come later when you set
   up indexers.
8. **Settings → General → Security:** record the **API Key** — you'll need it
   in Bazarr (one per instance, so two keys total).
9. **Settings → Metadata:** leave **all providers OFF** (the default).
   Sonarr writes metadata for Kodi-style consumers; Jellyfin fetches its
   own from TMDB/TVDB and is the more capable pipeline (richer provider
   ordering, lockable fields, UI-driven match fixing). NFO sidecars in
   the library tree fight Jellyfin's own fetch and make refresh-from-
   source unpredictable. Community consensus (TRaSH, Servarr wiki, r/
   jellyfin) is to let Jellyfin own metadata in \*arr+Jellyfin setups.

### 1.3 — Radarr first-run (do on **both** bose and ravennue)

Same shape as Sonarr, with movie-flavored differences. As with §1.2, the
root folder and quality profile differ per instance; everything else is
identical.

1. Authentication: Forms, password, Required.
2. **Settings → Media Management → File Management:**
   - Use Hardlinks instead of Copy: **ON**
   - Import Extra Files: **ON** (`srt,sub,nfo`)
   - Analyze video files: **ON** — required so MediaInfo tokens
     (`{Mediainfo VideoCodec}`, `{MediaInfo VideoDynamicRangeType}`,
     etc.) populate during Rename Files. Without it, Radarr falls
     back to filename guessing, which the pre-rename tool's scaffold
     filenames don't carry.
   - Set Permissions: **OFF** — same rationale as §1.2: the filesystem
     layer (`filebot-ingest` umask + setgid parents) already produces
     the right modes, and Radarr's `chown`/`chmod` attempt fails with
     EPERM since FileBot-created files are owned by the operator, not
     `media`.
3. **Settings → Media Management → Movie Naming:**
   - Rename Movies: **ON**
   - Standard Movie Format (TRaSH): `{Movie CleanTitle} ({Release Year}) {edition-{Edition Tags}} [{Custom Formats}]{[Quality Full]}{[MediaInfo 3D]}{[MediaInfo VideoDynamicRangeType]}[{Mediainfo VideoBitDepth}bit]{[Mediainfo VideoCodec]}{-Release Group}`
   - Movie Folder Format: `{Movie CleanTitle} ({Release Year})`
4. **Add Root Folder** — **per-instance**:
   - **bose**: `/media/library-hq/movies`
   - **ravennue**: `/media/library/movies`
5. **Quality Profile** — same per-instance rule as §1.2 step 6:
   bose 2160p-only, ravennue ≤1080p only.
6. **Indexers / Download Clients:** leave empty.
7. **Settings → General:** record the **API Key** (one per instance).
8. **Settings → Metadata:** leave **all providers OFF** (default). Same
   rationale as §1.2 step 9 — Jellyfin owns metadata; NFO sidecars from
   Radarr would fight its fetch.

### 1.4 — Jellyfin API key (on oracion)

Before configuring Connect on Sonarr/Radarr, generate a Jellyfin API key:

1. Browse `https://oracion.internal/` (or whatever DNS / reverse proxy you
   use).
2. **Dashboard → API Keys → +** (top right). Name it `arr-stack`.
3. Copy the key.

### 1.5 — Wire Sonarr/Radarr → Jellyfin (Connect)

Do this **once per arr instance** — that's four separate Connect entries
(bose Sonarr, bose Radarr, ravennue Sonarr, ravennue Radarr), all pointing
at the same Jellyfin and using the same API key.

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
Then repeat both on the other guest's UI.

### 1.6 — Bazarr first-run (on bose only — covers both instances)

Bazarr only runs on bose, but it natively supports multiple Sonarr/Radarr
providers via the **+ Add** button — one per arr instance. After this
step Bazarr fetches subtitles for both the HQ tier library (bose's arrs)
and the default tier library (ravennue's arrs).

1. Authentication: Forms, password, Required.
2. **Settings → Sonarr:** add **two** entries with **+ Add**:
   - First entry — bose's Sonarr (HQ tier):
     - Address: `127.0.0.1` (or `bose.internal`)
     - Port: `8989`
     - API Key: bose Sonarr's key from §1.2
     - **Test** → green.
   - Second entry — ravennue's Sonarr (default tier):
     - Address: `ravennue.internal`
     - Port: `8989`
     - API Key: ravennue Sonarr's key from §1.2
     - **Test** → green.
3. **Settings → Radarr:** same shape, two entries:
   - bose's Radarr — `127.0.0.1:7878`, bose Radarr API key.
   - ravennue's Radarr — `ravennue.internal:7878`, ravennue Radarr API key.
4. **Settings → Languages:**
   - Enabled Languages: pick your wanted language(s), e.g. English.
   - Create a **Language Profile** with the wanted languages, set as default
     for both Sonarr and Radarr (Settings → Sonarr / Radarr → Default
     settings) — applies to all provider entries.
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

The staging zones are split per tier at the top level:

```
/data/media/staging/manual/movies/        ← SD / 1080p (→ ravennue)
/data/media/staging/manual/tv/            ← SD / 1080p (→ ravennue)
/data/media/staging/manual/music/         ← (Lidarr is future work)
/data/media/staging-hq/manual/movies/     ← 2160p / UHD (→ bose)
/data/media/staging-hq/manual/tv/         ← 2160p / UHD (→ bose)
```

The parent dir (`staging` vs `staging-hq`) is the tier signal. Whether
you stage from the liberl host shell, either guest, an SMB share, or
rsync over SSH, they all converge on the same inode tree (the
`data/media` ZFS dataset).

**Tier decision (the moment you stage a file):** does the filename
contain `2160p`, `UHD`, or `4K`? Drop it under `staging-hq/manual/`. If the
filename is ambiguous, probe the file:

```bash
ssh root@bose.internal -- 'mediainfo /media/staging/manual/movies/<file>.mkv | grep -E "^(Width|Height)"'
# Width >= 3840 (or Height >= 2160) → 4K → put it under staging-hq/manual/.
# Otherwise → staging/manual/.
```

`mediainfo` and `ffprobe` are installed on both guests for exactly
this check.

`staging*/` is **staging**, not the ingestion target. Phase 3 (FileBot)
reads from here and writes the renamed/nested output into the matching
tier's `/media/library*/<type>/` subdir. Phase 4 then runs Library Import

- Mass Edit Rename **on the matching instance's UI** (bose for the HQ
  tier, ravennue for the default tier).

Three ways to put files into the staging zone:

### 2.1 — From liberl itself (move from /data/old/)

Fastest for the migration: `/data/old/` is on the same ZFS pool but a
**different dataset** (the root dataset), so a `mv` will fall back to copy.
Use rsync to preserve attrs and remove sources, then tier-sort, then verify
and clean up.

The simplest sequence is: rsync everything into the **plain** (default-tier)
subdir first, then move HQ-tier files out into the `staging-hq/` variant using
filename heuristics. mediainfo can disambiguate the rest.

```bash
ssh root@liberl

# Movies — rsync into plain subdir first
rsync -aHAX --info=progress2 --remove-source-files \
  /data/old/media/movies/ /data/media/staging/manual/movies/

# TV
rsync -aHAX --info=progress2 --remove-source-files \
  /data/old/media/tv/ /data/media/staging/manual/tv/

# Music
rsync -aHAX --info=progress2 --remove-source-files \
  /data/old/media/music/ /data/media/staging/manual/music/

# Tier-sort by filename hint — anything with 2160p / UHD / 4K in the name:
find /data/media/staging/manual/movies -maxdepth 2 -type f \
  \( -iname '*2160p*' -o -iname '*UHD*' -o -iname '*4K*' \) \
  -exec mv {} /data/media/staging-hq/manual/movies/ \;

# TV is more often organized as Series/Season/episodes — move whole series
# directories whose names match, plus loose files matching the same pattern:
find /data/media/staging/manual/tv -mindepth 1 -maxdepth 1 -type d \
  \( -iname '*2160p*' -o -iname '*UHD*' -o -iname '*4K*' \) \
  -exec mv {} /data/media/staging-hq/manual/tv/ \;

# For files without obvious filename markers, probe from a guest:
#   ssh root@bose.internal -- 'mediainfo /media/staging/manual/movies/somefile.mkv | grep -E "^(Width|Height)"'
# Width >= 3840 → 4K → move into the matching staging-hq/manual/<type>/ by hand.

# Fix ownership and mode for the arr stack. rsync preserves the source
# uid/gid/mode, which won't match what the arr stack expects.
chown -R 400:400 /data/media/staging /data/media/staging-hq
find /data/media/staging /data/media/staging-hq -type d -exec chmod 2775 {} +
find /data/media/staging /data/media/staging-hq -type f -exec chmod 664  {} +

# Clean up empty directories left by --remove-source-files
find /data/old/media -type d -empty -delete
```

**Do this in batches.** A single `rsync` of the whole movies tree is fine for
files; the issue is each arr's RAM usage scales with how many files it sees
in Library Import. Stage 50–200 movie folders, import on the matching
instance, watch RAM, repeat. (Each guest has 8 GB RAM + zramSwap as a
safety valve, but bulk imports of large collections are the documented
worst case.)

### 2.2 — From a desktop via SMB

Liberl exposes the media share over SMB to the trusted VLAN:

- Share: `\\LIBERL\media`
- User: your Samba user (configured separately)
- Drop into: `\\LIBERL\media\staging\manual\movies\` (etc.)

After uploading, run on liberl to fix permissions:

```bash
chown -R 400:400 /data/media/staging /data/media/staging-hq
find /data/media/staging /data/media/staging-hq -type d -exec chmod 2775 {} +
find /data/media/staging /data/media/staging-hq -type f -exec chmod 664  {} +
```

(Samba writes files as the SMB user. New _directories_ under `staging*/`
inherit `group=media` from the setgid bit, but the _uid_ will be the SMB
user's, and _files_ keep the SMB user's umask — so a `chown` and a mode
sweep is still required after a batch upload. Or set `force user = media`
/ `force group = media` on the share if this becomes routine.)

### 2.3 — From a desktop via rsync/scp

```bash
rsync -aHAX --info=progress2 \
  ./local-pile/ \
  root@liberl.internal:/data/media/staging/manual/movies/   # or staging-hq/manual/movies/ for HQ tier

ssh root@liberl '
  chown -R 400:400 /data/media/staging /data/media/staging-hq
  find /data/media/staging /data/media/staging-hq -type d -exec chmod 2775 {} +
  find /data/media/staging /data/media/staging-hq -type f -exec chmod 664  {} +
'
```

## Phase 3: Required — pre-rename with FileBot

This is **not optional** for a bulk migration. Radarr's Library Import
scans for _per-movie subdirectories_ shaped like
`Movie Title (Year)/file.ext`, not loose files in the folder root. A
folder full of loose `.mkv` files will produce the misleading message
**"All movies in /media/library/movies have been imported"** — the
empty-state shown when zero movie-shaped subdirectories were found,
_not_ a confirmation that anything was actually imported. Sonarr's
Library Import has the same shape requirement for
`Series Title (Year)/Season NN/...`.

FileBot's job here is to do two things in one pass:

1. **Rename** files to a parseable `Title (Year).ext` (Radarr's parser
   needs both title and year — a year-less filename like `Big Hero 6.mkv`
   will not match any TMDB entry on its own).
2. **Nest** each file into a `Title (Year)/` subdirectory, which is
   what Library Import actually scans for.

The format strings below do both jobs. FileBot **writes directly into
the matching tier's `/media/library*/` tree**, not `/media/staging*/`,
because the workflow shape is "pre-rename → Library Import
(adopt-in-place) → Mass Edit Rename" — see §4 for the why.

### Why FileBot

FileBot is the pre-rename tool because it handles cases mnamer (the
previous tool) couldn't:

- **Multi-episode files** — single `.mkv` covering several aired
  episodes (common with DVD rips). FileBot's `{e.pad(2)}` binding
  expands to ranges like `S01E05-E07` automatically; mnamer can't model
  this case at all. Without correct multi-episode naming, Sonarr marks
  the covered episodes as missing.
- **DVD/absolute episode order** — for shows whose physical media uses
  a non-aired order (Futurama is the canonical case), FileBot exposes
  the alternate orderings via format bindings (`{dvd.s}`, `{absolute}`).
- **Anime, foreign titles, ambiguous matches** — FileBot's matching is
  hash-aware (OpenSubtitles / AniDB hash lookups) with richer per-DB
  settings than mnamer offered.
- **Same scaffold output** — for the 95% case (modern, well-named
  releases), FileBot produces the same `Title (Year)/Title (Year).ext`
  that mnamer did.

A FileBot license is required for full lookup functionality.

### Run as `mediaops`, not root

FileBot refuses to run as root by design (file operations as root are a
real foot-gun). bose has a dedicated `mediaops` role account
(`isNormalUser`, member of `media` group, no SSH keys) for ingest
tooling — `su` to it from the root SSH session before running
FileBot. The same account avoids EPERM/EACCES surprises with
`/media/library/...`: it's in the `media` group with the right umask
inherited from `filebot-ingest`, so FileBot creates files
group-writable and group=media (matching the setgid 2775 parent dirs
from `nas.nix`).

License activation lives at `/home/mediaops/.filebot/`, persisted via
`environment.persistence` in bose's `default.nix`.

**One-time activation** (after first deploying with the `mediaops`
user in place):

```bash
# Stage the .psm from passage on your workstation
passage show filebot/license > /tmp/filebot.psm
scp /tmp/filebot.psm root@bose.internal:/tmp/
shred -u /tmp/filebot.psm

# Activate as mediaops on bose
ssh root@bose.internal
chown mediaops:media /tmp/filebot.psm
su - mediaops
filebot --license /tmp/filebot.psm
filebot -script fn:sysinfo | grep -i license   # confirms active license
exit                                            # back to root
shred -u /tmp/filebot.psm
```

### What FileBot owns vs. what Radarr owns

FileBot produces a _parseable scaffold_ in `library*/`: enough name to
match TMDB/TVDB and pass Library Import. The canonical TRaSH naming
scheme from §1.2/§1.3 (quality/codec/HDR/audio/release-group) is applied
later by Radarr/Sonarr in §4 via Mass Edit → Rename Files, once the
arr has analyzed the actual video stream. FileBot doesn't need to
produce the final TRaSH name — that's what step 3 is for.

### Running FileBot

FileBot lives on bose only (the license is per-user, and both arr
guests see the same `/data/media` tree via virtiofs — single-host
ingest is sufficient). It's exposed as `filebot-ingest` (a wrapper
that forces `umask 0002` so the directories FileBot creates are
group-writable). What matters is the `--output` flag, which sets the
destination, and must match the tier of the input directory:

| Source                              | Output flag                         | Then import on |
| ----------------------------------- | ----------------------------------- | -------------- |
| `/media/staging/manual/movies/`     | `--output /media/library/movies`    | ravennue       |
| `/media/staging-hq/manual/movies/`  | `--output /media/library-hq/movies` | bose           |
| `/media/staging/manual/tv/`         | `--output /media/library/tv`        | ravennue       |
| `/media/staging-hq/manual/tv/`      | `--output /media/library-hq/tv`     | bose           |

Always run as `mediaops`, never as root (FileBot refuses root, and
running as `mediaops` keeps file ownership/group correct end-to-end):

```bash
ssh root@bose.internal
su - mediaops

# Movies — SD/1080p batch (→ ravennue's Radarr in §4.1). Dry run first.
filebot-ingest -rename /media/staging/manual/movies/ \
  --db TheMovieDB \
  --output /media/library/movies \
  --action test \
  --conflict skip \
  -non-strict \
  --format "{n} ({y})/{n} ({y})"

# Real run — switch --action to move
filebot-ingest -rename /media/staging/manual/movies/ \
  --db TheMovieDB \
  --output /media/library/movies \
  --action move \
  --conflict skip \
  -non-strict \
  --format "{n} ({y})/{n} ({y})"

# Movies — HQ batch (→ bose's Radarr). Same shape, swap paths.
filebot-ingest -rename /media/staging-hq/manual/movies/ \
  --db TheMovieDB \
  --output /media/library-hq/movies \
  --action move \
  --conflict skip \
  -non-strict \
  --format "{n} ({y})/{n} ({y})"

# TV — SD/1080p batch (→ ravennue's Sonarr).
filebot-ingest -rename /media/staging/manual/tv/ \
  --db TheTVDB \
  --output /media/library/tv \
  --action move \
  --conflict skip \
  -non-strict \
  --format "{n} ({y})/Season {s.pad(2)}/{n} - S{s.pad(2)}E{e.pad(2)} - {t}"

# TV — HQ batch (→ bose's Sonarr).
filebot-ingest -rename /media/staging-hq/manual/tv/ \
  --db TheTVDB \
  --output /media/library-hq/tv \
  --action move \
  --conflict skip \
  -non-strict \
  --format "{n} ({y})/Season {s.pad(2)}/{n} - S{s.pad(2)}E{e.pad(2)} - {t}"
```

`-non-strict` allows fuzzy matching when the exact title isn't found in
the DB; without it, FileBot bails on anything it can't match
unambiguously. `--conflict skip` leaves an existing destination file
alone rather than overwriting (safe default; switch to `override` if
you're intentionally re-ingesting).

After FileBot runs, each movie sits in its own
`/media/library{,-hq}/movies/Title (Year)/` directory and each TV file
sits in `library{,-hq}/tv/Series (Year)/Season NN/Series - SnnEnn - Title.ext`
— exactly what Library Import expects. The matching arr instance
adopts these in §4, then Mass Edit → Rename Files applies the full
TRaSH name in place.

### Edge cases

- **Multi-episode files** — when FileBot matches one file to multiple
  episodes, `{e.pad(2)}` automatically expands to a range
  (e.g. `S01E05-E07`). Sonarr's Library Import recognizes the range
  and links the file to all covered episodes. No special invocation
  needed.
- **DVD / absolute order** — for shows using non-aired ordering, swap
  `{s.pad(2)}E{e.pad(2)}` for `{dvd.s.pad(2)}E{dvd.e.pad(2)}` (or
  `{absolute}` for absolute-ordered anime) in the TV format. Always
  use `--action test` first to verify the new numbering before
  committing.
- **Genuinely unidentifiable files** (`movie01.mkv`, `disc1.mkv`) —
  FileBot can sometimes match these via hash (OpenSubtitles /
  AcoustID); use `--db OpenSubtitles` for a hash-driven retry pass.
  For the residue, hand-rename: `mv` into
  `Title (Year)/Title (Year).ext` directly.

## Phase 4: The actual ingestion (per-app workflow)

The shape is uniform across every arr-supported media type:

```
1. Pre-rename tool (FileBot) writes into /media/library{,-hq}/<type>/
2. arr Library Import wizard adopts in place    ←── on the matching instance
3. arr Mass Edit → Rename Files applies the canonical TRaSH name
```

Step 1 is Phase 3. Steps 2 and 3 happen inside the arr UI, **on the
instance whose root folder matches the tier** — bose for the HQ tier
(`library-hq/`), ravennue for the default tier (`library/`). Picking
the wrong UI gets you the empty-state message because that instance's
root folder doesn't see the files.

**Library Import is adopt-in-place** — it does not move, hardlink, or
rename. That's why we point it at `/media/library*/`, where FileBot has
already written the files: Library Import attaches the arr's database
record to the existing on-disk file. The MediaInfo-rich TRaSH name
comes from the Rename Files step, which is a rename within the same
dataset (link-preserving) and depends on **Analyze video files: ON**
(set in §1.2/§1.3) so quality/codec/HDR tokens populate from the
actual stream rather than from filename guessing.

### 4.1 — Radarr workflow (movies)

Run this on **ravennue's Radarr** for the default-tier batch (root folder
`/media/library/movies`), or on **bose's Radarr** for the HQ-tier batch
(root folder `/media/library-hq/movies`). The steps are identical
otherwise; the path substitution below uses `<root>` for the matching
folder.

**Prerequisite:** Phase 3 must be complete for the tier you're
importing. Each movie under `<root>` should sit in its own
`Title (Year)/` subdirectory containing the file FileBot wrote there.
If you skipped Phase 3, the Library Import wizard will say "All movies
in `<root>` have been imported" and show nothing — see Troubleshooting.

**Step 1: Library Import (adopt in place).**

1. Open the matching instance's Radarr UI (ravennue's for default tier,
   bose's for HQ tier). Sidebar → **Movies** → **Library Import** (top button, also
   reachable from Add New → Import Movies; URL is `/add/import`).
2. Folder: `<root>` — `/media/library/movies` for ravennue,
   `/media/library-hq/movies` for bose.
3. Radarr scans subdirectories and shows matched movies. Inspect:
   - Each row has the matched TMDB title, monitored status, quality
     profile, root folder.
   - **Set Quality Profile** (the per-instance one from §1.3 — bose's
     2160p-only, ravennue's ≤1080p) and **Monitored** in the bulk-edit
     bar at the top.
   - Verify each match is correct. Manually fix wrong matches by
     clicking the title and searching TMDB.
4. Select all → **Import** (top right).
5. Radarr now tracks each file in its DB but the on-disk filenames
   are still FileBot's scaffold (`Foo (2024).mkv`, no MediaInfo tokens).

**Step 2: Apply canonical TRaSH naming.**

1. Sidebar → **Movies** (the main library page).
2. Top bar → **Mass Editor** (sometimes labeled Mass Edit).
3. Select all rows in the batch you just imported (filter by date
   added if mixing with an existing library).
4. **Rename Files** action. Radarr probes each file's video stream
   (because Analyze video files is ON) and rewrites the filename to
   the §1.3 TRaSH format, e.g. on bose:
   ```
   /media/library-hq/movies/Foo (2024)/
     Foo (2024) [Bluray-2160p][HDR][HEVC]-RG.mkv
   ```
   or on ravennue:
   ```
   /media/library/movies/Bar (2024)/
     Bar (2024) [Bluray-1080p][HEVC]-RG.mkv
   ```
5. Verify on disk:
   ```bash
   ssh root@bose.internal     # or ravennue.internal — both see both trees
   ls /media/library-hq/movies/'Foo (2024)/'
   ```

**Step 3: Trigger a Jellyfin scan.**

In practice, Connect (set up in §1.5) does **not** fire reliably for
Mass Edit → Rename Files. The `On Rename` event is sent for per-movie
renames triggered from the movie page, but bulk renames via Mass Edit
silently skip the notification in current Radarr versions. The Test
button only verifies auth/reachability, not that events fire.

So after Step 2, manually kick a scan: oracion → Jellyfin Dashboard →
**Scheduled Tasks → Scan Media Library → Run**. Then verify under the
Movies / Movies HQ section (whichever matches the tier). Connect
remains useful as a best-effort signal for the cases where it does
fire (per-movie organize, future download-client imports), and
Jellyfin's 4-hour scheduled scan from Phase 5 is the no-click
fallback if you forget the manual run.

**Note:** Renames within `/media/library*/` are link-preserving on
the same ZFS dataset — the inode survives. If you previously had
hardlinks pointing into here (e.g., from a future download client,
or from the curated TV view at `library/tv-curated/`), they remain
valid after the Mass Edit Rename.

### 4.2 — Sonarr workflow (TV)

Same three-step shape as §4.1, run on the matching instance:
ravennue's Sonarr for the default tier (`/media/library/tv`),
bose's Sonarr for the HQ tier (`/media/library-hq/tv`).

**Step 1: Library Import.**

1. Open the matching instance's Sonarr UI. Sidebar → **Series** →
   **Import** (top button).
2. Folder: `/media/library/tv` (ravennue) or `/media/library-hq/tv`
   (bose).
3. Sonarr scans for series and lists each detected show.
4. For each show, set **Monitor**, **Quality Profile** (per-instance:
   bose 2160p-only, ravennue ≤1080p), **Series Type**
   (Standard/Daily/Anime). Root folder defaults to the folder you
   pointed it at.
5. Select all → **Import**.

**Step 2: Apply canonical TRaSH naming.**

1. Sidebar → **Series**.
2. Top bar → **Mass Editor**.
3. Select all rows in the batch.
4. **Rename Files** action. Sonarr renames every episode to the §1.2
   format, including all MediaInfo tokens.

**Step 3: Trigger a Jellyfin scan** — same caveat as movies (§4.1
Step 3): Mass Edit Rename doesn't reliably fire Connect. Run
**Dashboard → Scheduled Tasks → Scan Media Library** on oracion, then
verify under TV / TV HQ.

For lone episodes (not full seasons in their own folders), Sonarr may
want **Wanted → Manual Import** pointed at the same root folder
instead — same adopt-in-place behavior, finer-grained per-file
control. Follow with the same Mass Edit Rename step.

### 4.3 — Bazarr backfill

Once a batch is in any library subdir, Bazarr (running on bose) will
pick it up automatically — it polls **all four** of the configured
arrs (bose Sonarr/Radarr + ravennue Sonarr/Radarr) on a schedule. To
force a sweep:

- Bazarr → **Series** / **Movies** → select all → **Mass Edit** → set
  Language Profile / Subtitles → Save.
- Or: **System → Tasks** → run **Sync with Sonarr** / **Sync with Radarr**
  manually. Run it once for each of the four provider entries.

## Phase 5: Verifying Jellyfin sees the imports

1. Jellyfin should auto-update via Connect within seconds of an import. If
   it doesn't:
   - Dashboard → Logs — look for the API call from the matching arr
     instance (bose for HQ tier, ravennue for default tier).
   - Dashboard → Scheduled Tasks → run **Scan Media Library** manually.
2. **Set up the scheduled fallback** (do once): Dashboard → Scheduled Tasks
   → Scan Media Library → set to run every 4 hours. inotify doesn't work
   over NFS, so this is your safety net for any Connect failure.
3. **Library configuration** (do once, if not already) — Jellyfin needs
   one library entry **per tier** so the UI can present them as separate
   collections:
   - Dashboard → Libraries → Add Media Library
   - **Movies** library, folder `/media/library/movies`
   - **Movies HQ** library, folder `/media/library-hq/movies`
   - **TV Shows** library, folder `/media/library/tv`
   - **TV Shows HQ** library, folder `/media/library-hq/tv`
   - **Music** library, folder `/media/library/music`
   - Real-time monitoring: **OFF** (no inotify on NFS).

   `library/tv-curated/` exists as a sibling tree for shows whose
   physical media follows a non-aired ordering (Futurama is the
   driving case) — out of scope for this runbook. The
   curated-view ownership model and Jellyfin wiring are TBD; see
   `llm-notes/specs/jellyfin-media-organization.md`.

## Phase 6: When the ingestion is done

1. Verify everything you wanted is in `/data/media/library/` and
   `/data/media/library-hq/`. Compare against an inventory of
   `/data/old/media/` (if it still exists).
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

4. Future ingestion is the same workflow without the old-collection
   rsync: tier-sort new files into the matching staging dir
   (`staging/manual/<type>/` for default, `staging-hq/manual/<type>/` for HQ
   tier), run FileBot pointed at the matching library tier
   (`library/<type>/` or `library-hq/<type>/`), then Library Import
   - Mass Edit Rename on the matching instance (bose for HQ tier,
     ravennue for default tier).

## Troubleshooting

**Library Import says "All movies in /media/library/<root> have been
imported" but the Movies page is empty.** This is the runbook's most
common confusing failure. The message is a vacuously-true empty state,
_not_ an import confirmation. Two possible causes:

1. **You're on the wrong instance.** ravennue's Radarr only sees
   `/media/library/movies`; bose's only sees `/media/library-hq/movies`.
   Pointing bose's Library Import at `/media/library/movies` will show
   the empty state because that path isn't its root folder. Switch
   browsers to the matching instance for the tier.
2. **Files aren't in per-movie subdirectories.** Library Import scans
   for `Title (Year)/` subfolders. Loose files in the folder root are
   invisible to it. Confirm from either guest:

```bash
ssh root@bose.internal
ls /media/library/movies/      # ravennue's tier; should be Title (Year)/ subdirs
ls /media/library-hq/movies/   # bose's tier; same
```

Fix by running Phase 3 (FileBot with the folder-creating format
string). To smoke-test before re-running FileBot over the whole tree,
hand-create one folder:

```bash
ssh root@liberl
cd /data/media/library/movies
mkdir -p 'Some Movie (2024)' && mv 'Some Movie (2024).mkv' 'Some Movie (2024)/'
chown -R 400:400 'Some Movie (2024)'
```

Re-run Library Import. If that one row appears, structure was the
issue.

**Mass Edit → Rename Files produces names like
`Foo (2024) [Unknown].mkv`** (no codec, no resolution, no HDR token).
**Analyze video files** is OFF in Settings → Media Management → File
Management. Without it, Radarr/Sonarr take quality/codec/HDR from the
filename — and FileBot's scaffold filenames don't carry that. Toggle
it ON (see §1.2 / §1.3), then **Mass Editor → Rename Files** again.
The second pass picks up the now-populated MediaInfo tokens.

**Movies page shows "No movies found, to get started you'll want to add
a new movie or import some existing ones."** This is Radarr's default
empty-state for the Movies page when its DB has no movie records — it is
not a sign that an import failed. To run an import you have to navigate
to the **Library Import** page (`/add/import`, or Movies sidebar →
Library Import button at the top, or Add New → Import Movies tile).
Filters at the top of the Movies page (Monitored / Missing / etc.) can
also hide entries that _do_ exist; switch to "All" to rule that out.

**Radarr logs show `SkyHookProxy.GetTrendingMovies` or
`UpdatePackageProvider.GetLatestUpdate` timeouts.** Both are outbound
HTTPS calls. A handful at boot is normal — bose's network or the gateway
isn't fully up yet when Radarr fires its first health-check sweep. The
test is whether they recur during normal operation: re-run the curls
from §0.4. If those succeed, the boot-time errors are cosmetic. If they
fail, the egress allowlist or upstream DNS/NAT is the problem (see §0.4).

**Hardlink fails with EXDEV.** Some operation tried to hardlink across
filesystem boundaries. The whole `data/media` tree must be one ZFS
dataset — verify with `zfs list -r data/media`, must show exactly one
row. If there are children, they need to be merged. (Relevant for
future download-client integration; not currently an active path now
that FileBot writes directly into `library/`.)

**Permission errors during import.** The arr services run as their service
user but with `group = "media"` (gid 400). Files in `staging*/` must be group
`400` and group-readable; directories must additionally be group-writable
(mode `2775`) so arr can hardlink/move into and out of them. The library
trees are enforced at `2775` by `systemd.tmpfiles.rules` in
`hosts/liberl/nas.nix` — but external writers (SMB, scp, rsync from
elsewhere) can introduce files with the wrong owner or mode. After any
non-arr write into `staging*/`:

```bash
chown -R 400:400 /data/media/staging /data/media/staging-hq
find /data/media/staging /data/media/staging-hq -type d -exec chmod 2775 {} +
find /data/media/staging /data/media/staging-hq -type f -exec chmod 664  {} +
```

If even `library*/` themselves look wrong (e.g. someone manually
`mkdir`'d a subdir without setgid), re-apply tmpfiles:
`systemd-tmpfiles --create`.

**Radarr OOM during bulk import.** Each guest has 8 GB + zramSwap. If
Radarr still OOMs, work in smaller batches (≤200 movies at a time), or
temporarily bump `microvm.mem` in the affected guest's `microvm.nix`
(`hosts/liberl/microvm/guests/{bose,ravennue}/microvm.nix`) to 16384
just for the migration, then drop it back.

**Jellyfin doesn't update after an import.** Check in order:

1. On the affected arr instance: Settings → Connect → Test the Jellyfin
   connection.
2. From the affected guest: `curl -v http://oracion.internal:8096/` —
   should be 302. If not, the egress filter on that guest or the
   lab→dmz forward rule is the issue.
3. On oracion: `journalctl -u jellyfin -n 100` — look for incoming API
   calls (the `User-Agent` header identifies the source instance).
4. Trigger a manual scan via Dashboard → Scheduled Tasks.

**`/media/library*/` looks wrong from oracion's side but right from a
guest.** The NFS RO mount on oracion (or calvard) is stale. From
oracion: `umount /media; ls /media` (the automount will remount it).
Or restart the microvm.

**arr stack runs but virtiofs `/media` is empty inside a guest.** Check
that `/data/media` exists on liberl and contains the staging tree.
virtiofs shows whatever the host has at the time of the share — restart
`microvm@<guest>` (bose or ravennue) after host-side mount changes.

**A title shows up on the wrong instance.** Each instance only sees its
configured root folder, so Radarr/Sonarr can't accidentally import an HQ-tier
file via ravennue or vice-versa via Library Import. But once a download
client ships, an indexer might offer both encodings to whichever
instance asks. The quality profile lock from §1.2/§1.3 (bose 2160p-only,
ravennue ≤1080p) is what prevents that — confirm the profile in use is
restricted to the right qualities.

**SMB-uploaded files have wrong owner/group.** Samba writes as the SMB
user, not as `media`. After each batch upload run the chown + chmod sweep
from "Permission errors during import" above (targets `staging/` and
`staging-hq/`), or set `force user = media` / `force group = media` on the
share if this becomes routine.

## Reference: which path means what

| Where you are             | Drop / staging                                                                     | Library                                                                           |
| ------------------------- | ---------------------------------------------------------------------------------- | --------------------------------------------------------------------------------- |
| liberl host               | `/data/media/staging/manual/{movies,tv,music}/` and `staging-hq/manual/{movies,tv}/` | `/data/media/library/{movies,tv,music,tv-curated}/` and `library-hq/{movies,tv}/` |
| bose guest (virtiofs)     | `/media/staging*/manual/...` (all tiers visible)                                   | `/media/library-hq/{movies,tv}/` (its own tier)                                   |
| ravennue guest (virtiofs) | `/media/staging*/manual/...` (all tiers visible)                                   | `/media/library/{movies,tv}/` (its own tier)                                      |
| oracion guest (NFS RO)    | _(not visible)_                                                                    | `/media/library*/...` (both tiers, read-only)                                     |
| Desktop via SMB           | `\\LIBERL\media\staging\manual\` and `\\LIBERL\media\staging-hq\manual\`           | _(visible, but don't write)_                                                      |

Both arr guests _see_ every tier under `/media/library*/` via virtiofs,
but each only **operates** on its own root folders (configured in §1.2 /
§1.3). The asymmetric visibility on oracion is the security boundary:
Jellyfin literally cannot see the staging directories.

| Tier                      | Staging                                    | Library                             | Operated by             |
| ------------------------- | ------------------------------------------ | ----------------------------------- | ----------------------- |
| Default                   | `/data/media/staging/manual/movies/`       | `/data/media/library/movies/`       | ravennue (Radarr)       |
| HQ                        | `/data/media/staging-hq/manual/movies/`    | `/data/media/library-hq/movies/`    | bose (Radarr)           |
| Default                   | `/data/media/staging/manual/tv/`           | `/data/media/library/tv/`           | ravennue (Sonarr)       |
| HQ                        | `/data/media/staging-hq/manual/tv/`        | `/data/media/library-hq/tv/`        | bose (Sonarr)           |
| Music                     | `/data/media/staging/manual/music/`        | `/data/media/library/music/`        | _(future Lidarr)_       |
| Console ROMs              | `/data/media/staging/manual/console/`      | `/data/media/library/software/console/`      | Igir                    |
| Romhacks                  | `/data/media/staging/manual/romhacks/`     | `/data/media/library/software/romhacks/`     | operator (manual mv)    |
| PC games                  | `/data/media/staging/manual/pc/`           | `/data/media/library/software/pc/`           | operator (manual mv)    |
| Curated TV (derived view) | _(none — no staging)_                      | `/data/media/library/tv-curated/`   | _(derive script — TBD)_ |

Subtitles for all four video tiers come from Bazarr on bose, which has
all four arrs (bose Sonarr/Radarr + ravennue Sonarr/Radarr) configured
as providers per §1.6.
