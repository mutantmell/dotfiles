# Plan: extend the media stack to handle music (FLAC + MP3, dual Lidarr)

## Goal

Add music ingestion and serving to the existing media pipeline, reusing
the dual-instance tier topology already established for video. The user
keeps both **FLAC** (lossless) and **MP3** (lossy) copies of the same
albums; Lidarr's single-file-per-record DB constraint means these must
live in separate Lidarr instances, in the same way 4K and 1080p video
already do for Radarr/Sonarr.

End state, by tier (post-rename, see §0):

| Tier          | Audio | Video  | Library path                    | \*arr instance |
| ------------- | ----- | ------ | ------------------------------- | -------------- |
| HQ / lossless | FLAC  | 2160p  | `library-hq/{music,movies,tv}/` | bose           |
| Default       | MP3   | ≤1080p | `library/{music,movies,tv}/`    | ravennue       |

Lidarr lives **alongside** Sonarr/Radarr on each of the two existing arr
microVMs — no new VMs. Music streaming is served by **Navidrome** on the
serving side (calvard/oracion), reading both tiers via the existing
RO NFS mount. Tag correction during the one-time migration is handled
by **MusicBrainz Picard** on bose, mirroring FileBot's role for video.

## §0 — Resolve the naming question first: rename `library-4k/` → `library-hq/`

Doing this **now**, before music ingestion, is the cheapest moment.
The user has confirmed that `library-4k/` currently holds very few
files, so the migration is essentially path-substitution + a
wipe-and-redo of bose's \*arr DBs — no data movement.

### Decision: rename, using the just-rename approach

**Why rename:** the tier abstraction is "quality / lossless-vs-lossy",
not "4K resolution". Once music is in `library-4k/music/`, the name
actively misleads anyone reading the tree without context. A
`library-hq/` name (matching `manual-hq/`) generalizes cleanly across
video, audio, and any future media type (audiobooks-lossless,
photos-RAW, …) without ever needing another rename.

**Why the just-rename approach (vs. a bind-mount alias):** with
`library-4k/` near-empty, wipe-and-redo on bose is cheaper than
maintaining a transitional bind-mount alias. The wipe-and-redo
procedure is already in the playbook (`ravennue-instance.md` §6.2).

### Migration steps (one-time, before §1 below)

The rename touches three layers: filesystem (tmpfiles + `mv`), \*arr
root folders (first-run on bose), Jellyfin library paths (UI on
oracion). All three live above the data — no copy-the-tree step.

**Pre-flight inventory** (sanity-check that the tree really is small;
if it's not, switch to a bind-mount alias rather than wipe-and-redo):

```bash
ssh root@liberl
du -sh /data/media/library-4k /data/media/manual-4k
ls /data/media/library-4k/{movies,tv}/
ls /data/media/manual-4k/{movies,tv}/
```

**Execution:**

1. **Prepare the Nix + doc PR** (uncommitted/unmerged is fine):
   - `hosts/liberl/nas.nix`: sweep `library-4k` → `library-hq` and
     `manual-4k` → `manual-hq` across the existing `dir` entries.
     The `# add 'library-4k/tv-curated/' when needed` comment at line
     73 is prose — rewrite manually rather than blindly substituting.
   - Doc sweep:
     ```bash
     sed -i 's,library-4k,library-hq,g; s,manual-4k,manual-hq,g' \
       llm-notes/specs/jellyfin-media-organization.md \
       llm-notes/guides/media-ingestion-runbook.md \
       llm-notes/guides/media-ingestion-runbook.md \
       llm-notes/wip/liberl-deployment-checklist.md
     # Leave ravennue-instance.md and plans/media-organization-pipeline.md
     # historical for audit trail.
     ```
     Eyeball the diff — passages explaining _why_ the name was `-4k`
     should be rewritten manually, not blindly substituted.
   - `nix fmt && ./scripts/run-checks.sh` — confirm flake still
     evaluates.
2. **Quiesce bose's writers.** On liberl:
   `systemctl stop microvm@bose`.
3. **Rename on disk.** Single ZFS dataset, so `mv` is inode-preserving
   and instant:
   ```bash
   mv /data/media/library-4k /data/media/library-hq
   mv /data/media/manual-4k  /data/media/manual-hq
   ```
4. **Deploy liberl** with the prepared Nix changes. systemd-tmpfiles
   sees the new `library-hq`/`manual-hq` entries and the renamed dirs
   match. (Without the deploy, on next service-start tmpfiles would
   re-create empty `library-4k`/`manual-4k` directories.)
5. **Wipe bose's persist volume** so first-run sets the new root
   folders directly (per `ravennue-instance.md` §6.2):
   ```bash
   rm /persist/guests/bose/images/persist.img
   systemctl start microvm@bose
   ```
   The microvm.autoCreate flag re-creates an empty 10 GB volume,
   services come up first-run.
6. **Re-run bose's first-run UI config** per the runbook §1.2 / §1.3 /
   §1.5 / §1.6 with the **new** root folders:
   `/media/library-hq/{tv,movies}` for Sonarr/Radarr.
   (Lidarr root folder is added in PR 2; not part of this PR.)
7. **Update Jellyfin libraries on oracion.** Either edit the existing
   "Movies 4K" / "TV Shows 4K" library entries to point at the new
   paths (and rename them to "Movies HQ" / "TV Shows HQ" while you're
   there), or delete + recreate. Either path is cheap; recreating is
   slightly cleaner.
8. **Re-import** the small amount of HQ video content on bose's
   Sonarr/Radarr against the new root folders.

### Files touched by the doc sweep

```bash
grep -rn "library-4k\|manual-4k" hosts/ llm-notes/ modules/
```

- `hosts/liberl/nas.nix` — tmpfiles entries
- `llm-notes/specs/jellyfin-media-organization.md` — spec text + addendum §6.2
- `llm-notes/guides/media-ingestion-runbook.md` — pervasive (paths in §0–§5)
- `llm-notes/wip/ravennue-instance.md` — **leave as-is** (historical plan)
- `llm-notes/plans/media-organization-pipeline.md` — **leave as-is** (older design doc)
- `llm-notes/guides/media-ingestion-runbook.md` — the active migration
- `llm-notes/wip/liberl-deployment-checklist.md` — references in checklist steps

The remainder of this plan uses **`library-hq/` and `manual-hq/`**.

## §1 — Storage layout

Add music to both tier roots, mirroring the existing video subdirs:

```
/data/media/
├── manual/
│   ├── movies/      ← already exists (default tier)
│   ├── tv/          ← already exists (default tier)
│   └── music/       ← already exists (default tier — MP3 staging)
├── manual-hq/       ← renamed from manual-4k
│   ├── movies/      ← already exists (HQ tier)
│   ├── tv/          ← already exists (HQ tier)
│   └── music/       ← NEW — FLAC staging
├── library/
│   ├── movies/      ← already exists
│   ├── tv/          ← already exists
│   ├── tv-curated/  ← already exists
│   └── music/       ← already exists (default tier — MP3 library)
└── library-hq/      ← renamed from library-4k
    ├── movies/      ← already exists
    ├── tv/          ← already exists
    └── music/       ← NEW — FLAC library
```

### Nix change — `hosts/liberl/nas.nix`

Add two `dir` entries to `systemd.tmpfiles.rules`:

```nix
(dir "/data/media/manual-hq/music")
(dir "/data/media/library-hq/music")
```

Same `2775 media:media` mode as everything else. Group ownership +
setgid means Lidarr (running as its own user with `group = "media"`)
can write into the tree.

The existing `/data/media/manual/music` and `/data/media/library/music`
entries already cover the default tier — no change needed there.

## §2 — Lidarr instances (one per arr microVM)

Same shape as the existing Sonarr/Radarr split. Each guest's
`modules/arr.nix` picks up `services.lidarr`, the firewall opens
port 8686, and the persist list grows by one entry.

### `bose/modules/arr.nix` — Lidarr (FLAC tier)

Add to the existing module:

```nix
services.lidarr = {
  enable = true;
  group = "media";
};

systemd.services.lidarr.serviceConfig = {
  Nice = 19;
  IOSchedulingClass = "idle";
  CPUWeight = 10;
};

environment.persistence."/persist".directories = [
  # ... existing sonarr/radarr/bazarr entries unchanged ...
  {
    directory = "/var/lib/lidarr";
    user = "lidarr";
    group = "media";
  }
];
```

### `ravennue/modules/arr.nix` — Lidarr (MP3 tier)

Identical `services.lidarr` and persistence block to bose's. Same
Nice/IO/CPU deprioritization.

### Firewall — both `bose/default.nix` and `ravennue/default.nix`

```nix
networking.firewall.allowedTCPPorts = [8989 7878 6767 8686];
#                                                       ^^^^ Lidarr
```

Both guests already share `oracion:8096` and `tharbad:{3100,8427}` in
the egress allowlist, plus the generic `tcp/{80,443}` rule for
metadata/MusicBrainz/Lidarr-update lookups — no egress changes are
needed for Lidarr.

### Why Lidarr on **both** instances

Lidarr (like Sonarr/Radarr) tracks one `TrackFile` per `Track` in its
DB. The same album encoded twice (FLAC + MP3) cannot coexist as two
files under one Lidarr instance — the second copy gets orphaned. The
only ways to keep both encodings tracked:

1. **Two Lidarr instances** — one per encoding tier. ← chosen
2. Single instance + accept that one encoding lives outside *arr
   management. Rejected: defeats the point of using *arr at all for
   the secondary encoding.

Option 1 is the same logic that drove the bose+ravennue split for
video, and the topology is already there to host it.

### Quality profile lock (per-instance, UI step)

Same enforcement strategy as for video:

- **bose Lidarr** — quality profile **"Lossless"**: include only the
  lossless qualities (FLAC primary, plus ALAC/WAV/AIFF if desired).
  Exclude every lossy quality.
- **ravennue Lidarr** — quality profile **"Lossy"**: include the lossy
  qualities you actually have (MP3 320 / V0 / V2 / 256, AAC-256, OGG,
  etc. — pick from Lidarr's actual quality list at first-run time).
  Exclude every lossless quality.

This mirrors the bose-2160p-only / ravennue-≤1080p-only locking from
§1.2/§1.3 of the runbook. It enforces tier separation for any future
indexer-driven import (out of scope here, but the lock is cheap to
set up now).

### Root folders (UI step, post-deploy)

- **bose Lidarr**: `/media/library-hq/music`
- **ravennue Lidarr**: `/media/library/music`

## §3 — Pre-rename / tag correction tool: MusicBrainz Picard

The video pipeline uses **FileBot** to produce a parseable scaffold
(`Title (Year)/`) before \*arr's Library Import adopts it. Lidarr's
Library Import has analogous expectations: the on-disk layout
must be `Artist/Album/track.ext` with sane metadata, otherwise the
match rate against MusicBrainz craters.

The standard tool here is **MusicBrainz Picard** (already named in
the spec at line 161/631). Picard's job is twofold:

1. Look up each track against MusicBrainz, write canonical tags
   (artist, album, MBID, release group, etc.) into the file.
2. Use the `$rename`/`File Naming` script to physically reorganize
   files into `Artist/Album/track.ext`.

Picard runs on **bose only**, like FileBot, for the same reasons:
both arr guests see the same `/data/media` tree via virtiofs, so
single-host ingest covers both tiers. Picard is GUI-driven, but it
exposes a CLI (`picard --no-gui`) that's good enough for batch
runs over an SSH X-forward or VNC session if a GUI on bose is too
much.

### Alternative considered: `beets`

`beets` is a strong CLI alternative — same MusicBrainz backend,
fully scriptable, no GUI dependency, ships in nixpkgs. It's a
better fit for "rsync drops a batch, run a one-liner, done"
workflows than Picard's GUI. Picard's only edge is interactive
disambiguation for ambiguous matches (a real issue with old or
poorly-tagged rips).

**Recommendation:** install **both** on bose. `beets` for the bulk
modern releases (95% of the collection), Picard for the residue
that needs hand-disambiguation. Same pattern as FileBot's
`-non-strict` happy path + manual residue.

### Nix change — `bose/modules/arr.nix`

```nix
environment.systemPackages = [
  pkgs.filebot
  filebot-ingest
  pkgs.mediainfo
  pkgs.ffmpeg-headless
  pkgs.picard           # NEW — MusicBrainz Picard
  pkgs.beets            # NEW — CLI MB tagger / organizer
];
```

If Picard's GUI is needed, X-forward via SSH or run via VNC. If a
GUI on bose is undesirable, drop Picard and rely entirely on beets;
the GUI step is only relevant for ambiguous-match disambiguation
during the migration, after which neither tool needs to run again.

### `mediaops` is the operator account here too

Same rationale as FileBot: don't tag/rename media as root, and files
written by `mediaops` (uid 1100 — normal-user range, allocated in
`lib/common/data/default.nix`; primary group `media` gid 400) match
the 2775 setgid parents declaratively. `bose/modules/arr.nix` already
defines this user; the same `umask 0002` wrapper pattern from
`filebot-ingest` should be applied to a `beets-ingest` /
`picard-ingest` shell wrapper if either tool's umask defaults
strip group-write. Verify post-deploy:

```bash
ssh root@bose.internal
su - mediaops
beet config | head -5
echo 'umask test'; touch /tmp/x; ls -l /tmp/x   # should be 664 / mediaops:media
```

## §4 — Music streaming: Navidrome on calvard

Jellyfin can serve music, but Navidrome is the spec's intended
streaming server (line 292) — Subsonic API support means clients
like Symfonium, DSub, play:Sub work without any server-side glue.

### Where it runs — co-locate inside oracion

The serving topology is calvard (Incus+microvm host) →
oracion (Jellyfin guest, NFS RO of `/mnt/media` via virtiofs).
**Recommendation: co-locate Navidrome inside oracion** rather than
standing up a new microVM.

**Why co-locate:**

- **Identical shape to Jellyfin.** Navidrome reads the same RO NFS
  mount, has the same threat model (RO-NFS-bound consumer of the
  organized library), and the same upstream egress profile (HTTPS to
  metadata providers — MusicBrainz, LastFM, Spotify, lyrics
  services). There is no meaningful security or blast-radius
  difference between the two services that a separate microVM would
  buy back.
- **Tiny resource footprint.** 50–100 MB idle, 200–300 MB on a full
  rescan (per the spec's RAM table). Adding a whole microVM —
  guest kernel, systemd, agents, virtiofs share, network tap, persist
  volume, deploy surface, monitoring — for ≤300 MB of workload is
  poor leverage.
- **One persist volume, one mount.** Navidrome's SQLite DB and
  search index can live alongside Jellyfin's persist directories on
  oracion. Same impermanence story.
- **Existing nginx + ACME-on-basel** on oracion picks up Navidrome
  as a second virtualHost (`navidrome.internal`) with the same cert
  flow already in place for Jellyfin. One TLS surface, one ACME
  config block per service.

**Trade-off accepted:** a Navidrome bug or runaway rescan can
pressure Jellyfin on the same guest. Mitigations are cheap if it
becomes an issue: systemd `MemoryMax=` / `CPUQuota=` on the
Navidrome unit caps the worst case, and splitting Navidrome out
into its own microVM later is mechanical (the persist data is
portable). Start co-located; split only if a real incident forces
it.

**The single-purpose-microVM convention** still holds for services
with distinct threat models (the RW-side arrs on bose/ravennue are
isolated from the RO-side consumers; that line stays). Bundling two
RO-NFS readers into one guest is consistent with the spirit of that
convention rather than a violation.

### Navidrome library configuration

Navidrome 0.55+ supports multiple libraries via the admin UI. The
two tiers map to two libraries:

- **Music** → `/media/library/music` (MP3, ravennue's Lidarr)
- **Music HQ** → `/media/library-hq/music` (FLAC, bose's Lidarr)

If Navidrome's multi-library support is awkward in practice (it has
historically been a sore spot — single-library is the older default),
the alternative is **transcode-on-demand**: point Navidrome at the
HQ tier only, configure a 320kbps transcode profile for clients
asking for compressed audio. This trades ingest-side dual-management
(this whole plan) for serve-side transcode CPU. The user explicitly
keeps both encodings, so the transcode path doesn't fully replace
the dual-tier on-disk layout — but it does mean Navidrome only needs
to scan one tier. Keep multi-library as the default; fall back to
single-library + transcode if multi-library proves flaky.

### Service-named vhosts: `navidrome.internal` and `jellyfin.internal`

Decision: while standing up Navidrome, also add a dedicated
`jellyfin.internal` vhost on oracion's nginx alongside the existing
`oracion.internal` one. Service-named vhosts are clearer for end
users and don't change if a service is later moved to a different
guest. The existing `oracion.internal` vhost can stay as a
transitional alias for a while, then be retired.

**DNS / network registry change** —
`lib/common/data/network.nix`, `hostAliases`:

```nix
hostAliases = {
  # ... existing entries ...
  oracion = [
    "jellyfin.internal.mutantmell.net"
    "jellyfin.internal"
    "navidrome.internal.mutantmell.net"
    "navidrome.internal"
  ];
};
```

This gets picked up by `mkUnboundAliasData` in phantasma's
`dns.nix` (already wired) and by `mkExtraHosts` callsites that
include oracion. After deploy, both names resolve to oracion's
IP from anywhere on the internal network.

### Nix sketch (oracion config, PR 3)

oracion's existing structure splits into `default.nix` (network /
egress / persist scaffolding) and `modules/jellyfin.nix` (the
service module). Navidrome follows the same shape — add
`modules/navidrome.nix` and import it from `default.nix`:

```nix
# modules/navidrome.nix
{config, pkgs, ...}: let
  vhost = "navidrome.internal";
in {
  services.navidrome = {
    enable = true;
    # No openFirewall — only basel-ACME-fronted nginx talks to it.
    settings = {
      Address = "127.0.0.1";   # bind localhost only; nginx fronts it
      Port = 4533;
      DataFolder = "/var/lib/navidrome";
      # Multi-library: set MusicFolder to a parent dir that contains
      # both, then configure each library via the admin UI. (Newer
      # Navidrome versions support a per-library config block; check
      # the nixpkgs version at deploy.)
      MusicFolder = "/media";
    };
  };

  # ACME cert for the service-named vhost via basel
  security.acme.certs."${vhost}".group = "acme-cert";

  services.nginx.virtualHosts."${vhost}" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:4533";
      extraConfig = ''
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/navidrome";
      user = config.users.users.navidrome.name;
      inherit (config.users.users.navidrome) group;
    }
  ];
}
```

### `jellyfin.internal` vhost — modify `modules/jellyfin.nix`

Add a sibling vhost block alongside the existing
`${config.networking.hostName}.internal` one. The cleanest pattern
is to factor the shared `jellyfinConf` config and the two
`locations` (`/` and `/socket`) into a `let` and assign both
vhost entries to the same value:

```nix
# modules/jellyfin.nix (sketch of the vhost change)
services.nginx.virtualHosts = let
  jellyfinVhost = { /* forceSSL, enableACME, locations as today */ };
in {
  "${config.networking.hostName}.internal" = jellyfinVhost;  # transitional
  "jellyfin.internal" = jellyfinVhost;
};

security.acme.certs."jellyfin.internal".group = "acme-cert";
```

Both vhosts proxy to the same `127.0.0.1:8096`. The existing
`oracion.internal` vhost stays as a transitional alias; retire
it in a follow-up PR after clients have migrated. The Jellyfin
`Dashboard → Networking → Published server URL` should be set
to `https://jellyfin.internal` so generated playback URLs use
the new name.

**Read access:** Navidrome runs as the `navidrome` user. NFS files
arrive squashed to `media:media` (uid/gid 400 via `all_squash`

- `anonuid=400/anongid=400` per `nas.nix`), mode 0664. Navidrome
  reads via the world-readable `o+r` bit — no need to add `navidrome`
  to the `media` group.

**Egress:** No changes to oracion's existing allowlist — the generic
`tcp/{80,443}` "any host" rule covers MusicBrainz, LastFM, lyrics,
and Navidrome update checks. ACME enrollment for the new vhosts
uses the existing `basel:443` rule.

**Multi-library:** the exact config syntax is version-dependent —
verify against the deployed nixpkgs Navidrome version. The NFS RO
mount and virtiofs share at `/media` are already in place for
Jellyfin; nothing on the calvard host or the share itself changes.

### Bazarr equivalent for music?

No. Music is shipped with embedded ID3 / Vorbis comments, and
synced lyrics are a non-essential nice-to-have. **Out of scope**
for this plan; defer until there's a concrete need.

## §5 — Runbook updates — `llm-notes/guides/media-ingestion-runbook.md`

Music gets a parallel section to the video flow, plus a few
inline path-substitution notes. Expected diffs:

- **§0.1 (preflight)** — add `ls /data/media/{manual,manual-hq}/music`
  to the directory check; existing `library/music` already there.
- **§1.1 (web UIs)** — add Lidarr URLs:
  `http://bose.internal:8686` (FLAC), `http://ravennue.internal:8686`
  (MP3).
- **NEW §1.7 — Lidarr first-run** (mirrors §1.2 / §1.3):
  - Authentication, Hardlinks ON, Set Permissions OFF
  - Track Naming: stick with the **Lidarr default** (`{Artist Name}/
{Album Title} ({Release Year})/{track:00} - {Track Title}.{ext}`
    or close). Match the format used by beets/Picard so the
    pre-rename and Lidarr's later rename agree, otherwise Mass Edit
    Rename will move every track on first import.
  - Root folder per instance (`/media/library-hq/music` for bose,
    `/media/library/music` for ravennue)
  - Quality profile lock per §2 above
  - Connect → Jellyfin (same API key, Update Library ON)
  - **No Connect → Navidrome.** Navidrome doesn't expose a webhook
    Lidarr knows how to fire; rely on Navidrome's scheduled scan
    (admin UI configurable, or trigger a manual rescan after a
    batch import).
- **§2 (staging)** — extend the tier-decision text to cover music:
  "is this lossless?" → `manual-hq/music/`; otherwise `manual/music/`.
  Filename hint: `.flac` / `.alac` / `.wav` → HQ. Otherwise probe with
  `ffprobe`/`mediainfo` for the codec.
- **NEW §3.x — pre-rename / tag with Picard or beets** — parallel to
  the FileBot section. Format string for both tools should produce
  `Artist/Album/Track.ext`. `beets import` is a reasonable default;
  fall back to Picard for hand-fixes.
- **§4.x — Lidarr workflow** — mirrors §4.1/§4.2. Library Import
  (adopt-in-place) → Mass Editor Rename (if naming changed). Note
  that Lidarr's Library Import scans for `Artist/Album/`-shaped
  subdirectories — same scaffold-shape requirement as
  Radarr/Sonarr.
- **§4.3 (Bazarr)** — note that Bazarr is video-only; no audio analog
  exists in this stack.
- **§5 (Jellyfin libraries)** — add `Music HQ` library at
  `/media/library-hq/music` if Jellyfin is to remain a music
  consumer alongside Navidrome.
- **Reference table** — add Music rows for both tiers, owned by
  bose's and ravennue's Lidarr respectively.

## §6 — Implementation order

The work splits cleanly into three PRs:

### PR 1 — `library-4k` → `library-hq` rename (§0)

1. Pre-flight inventory on liberl per §0 above. Confirms the tree is
   small enough for wipe-and-redo.
2. `systemctl stop microvm@bose`; `mv` both `library-4k` → `library-hq`
   and `manual-4k` → `manual-hq`.
3. Sweep `hosts/liberl/nas.nix` and the non-historical `llm-notes/`
   files per the §0 file list. Rewrite the prose passages that
   explain _why_ the name was `-4k`.
4. `nix fmt && ./scripts/run-checks.sh`.
5. Deploy liberl. New tmpfiles entries materialize.
6. `rm /persist/guests/bose/images/persist.img`; restart bose.
7. Re-run bose's first-run UI config with the new root folders.
8. Update Jellyfin libraries on oracion (delete + recreate as
   "Movies HQ" / "TV Shows HQ").
9. Re-import the small amount of HQ video on bose's Sonarr/Radarr.

### PR 2 — Lidarr on both arr guests (§1, §2, §3)

1. Storage tmpfiles — add `library-hq/music` and `manual-hq/music`
   to `hosts/liberl/nas.nix`.
2. Lidarr Nix changes — `services.lidarr` + persist entry + firewall
   port 8686 on both `bose/modules/arr.nix` and
   `ravennue/modules/arr.nix`. Add `pkgs.picard` and `pkgs.beets` to
   bose's `systemPackages`.
3. Optional `beets-ingest` / `picard-ingest` umask wrappers if
   testing shows default umask strips group-write (mirrors
   `filebot-ingest`).
4. `nix fmt && ./scripts/run-checks.sh`. No new VM tests — modules
   are vanilla NixOS, existing infra checks cover the surrounding
   ground.
5. Deploy liberl + bose + ravennue. Lidarr starts first-run on both.
6. Lidarr first-run UI on each guest per the runbook §1.7 below.
   Quality profile locks (Lossless on bose, Lossy on ravennue),
   root folders, Connect → Jellyfin.
7. Tag-and-ingest a small batch end-to-end:
   - Stage one FLAC album under `manual-hq/music/`.
   - Run `beets import` (or Picard) as `mediaops` on bose → writes
     `Artist/Album/track.flac` into `library-hq/music/`.
   - On bose's Lidarr: Library Import → adopt-in-place.
   - Verify in Jellyfin "Music HQ" library after a scheduled scan.
   - Repeat with one MP3 album under `manual/music/` against
     ravennue's Lidarr.
8. Update the runbook (§5 of this plan).

### PR 3 — Navidrome on oracion + service-named vhosts (§4)

1. **Network registry** — add the four oracion aliases
   (`jellyfin.internal`, `jellyfin.internal.mutantmell.net`,
   `navidrome.internal`, `navidrome.internal.mutantmell.net`) under
   `hostAliases` in `lib/common/data/network.nix`.
2. **`modules/navidrome.nix`** — new file on oracion: `services.navidrome`,
   the `navidrome.internal` nginx vhost (basel ACME, proxy to
   127.0.0.1:4533), persist entry. Imported from
   oracion's `default.nix`.
3. **`modules/jellyfin.nix`** — add the `jellyfin.internal` sibling
   vhost (factor the existing one, same proxy target). Both vhosts
   live until clients migrate; keep `oracion.internal` as a
   transitional alias.
4. `nix fmt && ./scripts/run-checks.sh`.
5. Deploy phantasma (DNS picks up the new aliases via
   `mkUnboundAliasData`), then calvard/oracion.
6. **Verify DNS** — from a workstation:
   `getent hosts jellyfin.internal navidrome.internal` resolves to
   oracion's IP.
7. **Verify ACME** — on oracion: `systemctl status acme-jellyfin.internal
acme-navidrome.internal` succeeded; `curl -v
https://jellyfin.internal/` and `https://navidrome.internal/`
   complete with the expected TLS chain (intermediate from basel).
8. **Navidrome first-run** — browse to `https://navidrome.internal`,
   complete admin signup, then create the two libraries (`Music` →
   `/media/library/music`; `Music HQ` → `/media/library-hq/music`).
   If multi-library proves flaky on the deployed Navidrome version,
   fall back to a single library + transcode profile per §4 above.
9. Confirm both tiers' contents appear; trigger a manual rescan if
   needed.
10. **Jellyfin published URL** — Dashboard → Networking → set
    Published server URL to `https://jellyfin.internal`.

### Then — bulk migrate the rest of the music collection

Per the runbook (with the music-flavored sections from §5 of this
plan added), tier-sort each batch into `manual/music/` or
`manual-hq/music/`, tag with beets/Picard, Library Import on the
matching Lidarr instance, verify in Navidrome.

## §7 — Test plan

Operational, no NixOS test harness. Per-PR verification:

### After PR 1 (rename)

1. `nix fmt && ./scripts/run-checks.sh` baseline + post-change.
2. On liberl: `ls /data/media/library-hq /data/media/manual-hq`
   shows the renamed trees (`movies`, `tv`, mode 2775, owned 400:400);
   `ls /data/media/library-4k` returns ENOENT.
3. From bose: `ls /media/library-hq/{movies,tv}` resolves; bose's
   Sonarr/Radarr UIs show the new root folders post-first-run.
4. From oracion: `ls /media/library-hq` resolves read-only;
   Jellyfin "Movies HQ" / "TV Shows HQ" libraries scan and find the
   re-imported HQ video content.

### After PR 2 (Lidarr)

1. `systemctl status microvm@bose microvm@ravennue` healthy on liberl.
2. On each arr guest: `systemctl status lidarr` running.
3. `curl -s http://bose.internal:8686/ping` and the same against
   ravennue return a Lidarr response.
4. From either arr guest: `ls /media/{library,library-hq,manual,manual-hq}/music`
   exists, mode 2775, owned 400:400.
5. Live test (FLAC album on bose):
   - `rsync` one FLAC album to
     `liberl:/data/media/manual-hq/music/Artist/Album/`.
   - `ssh root@bose.internal; su - mediaops; beet import
/media/manual-hq/music/Artist` — completes without errors,
     writes `Artist/Album/track.flac` into `/media/library-hq/music/`.
   - bose Lidarr → Library Import → `/media/library-hq/music`. Album
     adopted, monitored, on the Lossless quality profile.
   - Jellyfin "Music HQ" library shows the new album (after a
     scheduled scan or manual rescan; Connect should also fire).
6. Live test (MP3 album on ravennue): same flow, lossy paths,
   ravennue Lidarr.
7. Cross-instance independence: dropping a FLAC into
   `manual/music/` (default tier, ravennue's territory) should not
   surface on bose's Lidarr; dropping an MP3 into `manual-hq/music/`
   should not surface on ravennue's. Each instance only sees its
   configured root folder.
8. Quality profile lock smoke-test: in each Lidarr UI, attempt to
   manually mark a release of a non-matching quality as wanted. The
   profile should not include it as an option.
9. NFS visibility: from oracion, `ls /media/library-hq/music` shows
   the FLAC album read-only; `touch /media/library-hq/music/.x`
   fails with EROFS.

### After PR 3 (Navidrome)

1. On oracion: `systemctl status navidrome` running.
2. From a workstation, browse to Navidrome's URL (the chosen vhost or
   `:4533` direct). Admin login completes.
3. Both libraries scan: "Music" populated from `/media/library/music`
   (MP3), "Music HQ" from `/media/library-hq/music` (FLAC).
4. Play one track from each library through a Subsonic client (or
   Navidrome's web UI) — confirms file read works through the
   squash-uid path.

## §8 — Future / non-blocking

- **Recyclarr music profiles.** TRaSH guides have a music section
  (much smaller than video). Wire when both Lidarr instances are
  stable, like Recyclarr is wired for the existing arrs.
- **Audiobookshelf** is a separate axis (audiobooks vs music) — out
  of scope here. Spec already has a row at line 293.
- **Lyrics** (sidecar `.lrc` files, or Bazarr-equivalent like LRCLib).
  Defer.
- **Auto-import on file drop** — Lidarr has an Import List feature;
  initial migration is Manual Import, future automation is a
  separate plan.
- **Single-pass tagging from a download client** — Lidarr → SABnzbd /
  Transmission post-processing. Out of scope until indexers and a
  download client are deployed for the video tier first; that work
  generalizes to music with no extra infra.
- **Resource ceiling.** Lidarr's spec'd 200 MB–1 GB peak fits inside
  each guest's 8 GB allocation alongside Sonarr/Radarr (combined peak
  steady-state ~3 GB on the 1080p side, ~1 GB on the 4K side per the
  RAM table in the spec). If bulk import OOMs, same remedy as the
  Radarr troubleshooting note in the runbook — bump `microvm.mem`
  for the migration window.
