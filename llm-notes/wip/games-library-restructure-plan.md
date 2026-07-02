# Plan: Games library restructure — DAT-vs-non-DAT split + staging rename

Status: WIP as of 2026-07-02. The code-side Nix changes have landed in the
flake: `hosts/liberl/nas.nix` declares the new `staging/`, `staging-hq/`, and
`library/software/{console,pc}` trees, and Retrom on `oracion` scans
`/media/library/software/console` plus `/media/library/software/pc`. The plan
remains WIP because repo state cannot prove the live liberl data migration,
arr-stack manual-import reconfiguration, Retrom first-scan validation, MISTer
symlink validation, or historical-note cleanup.

Successor to `llm-notes/done/retrom-game-pipeline.md`. That plan
established the games pipeline (Retrom on oracion, Igir on bose, MISTer
hardlink view). This plan does two things at once:

1. Reshapes the on-disk games layout to use a single `console/` tree
   with Igir's `{type}` token as an intermediate directory level
   (e.g. `Retail/`, `Hacks/`, `Translated/`), keeping official and
   community-modified ROMs visually distinct without separate content roots.
2. Introduces a `staging/` (and `staging-hq/`) parent directory for all
   source material — manual rips today, future downloader output
   (Syncthing, torrents, usenet) tomorrow. This is a top-level tree
   rename that affects movies/tv/music as well as games.

## Goal

```
/data/media/
├── library/                       # default tier — canonical, ready for clients
│   ├── movies/                    # unchanged
│   ├── tv/                        # unchanged
│   ├── tv-curated/                # unchanged
│   ├── music/                     # unchanged
│   └── software/                  # NEW parent for all games content
│       ├── console/               # NEW — all ROMs; type subdirs per platform
│       │   └── Nintendo - Super Nintendo Entertainment System/
│       │       ├── Retail/        # DAT-verified, Igir-canonical
│       │       │   └── <game>/
│       │       └── Hacks/         # operator-curated patched ROMs
│       │           └── <game>/
│       └── pc/                    # NEW — operator-curated PC games (folder-per-game)
│           └── <Title>/
├── library-hq/                    # HQ tier — canonical (unchanged)
│   ├── movies/, tv/, music/
├── staging/                       # NEW parent for default-tier source material
│   └── manual/                    # was /data/media/manual/ — renamed by being moved
│       ├── movies/                # preserved contents
│       ├── tv/                    # preserved contents
│       ├── music/                 # preserved contents
│       ├── console/               # NEW — raw / unverified ROM dumps before Igir
│       ├── romhacks/              # NEW — patched / community ROM hacks
│       └── pc/                    # NEW — incoming PC installers / extracted dirs
├── staging-hq/                    # NEW parent for HQ-tier source material
│   └── manual/                    # was /data/media/manual-hq/ — renamed (no `-hq` suffix; parent signals tier)
│       ├── movies/                # preserved contents
│       ├── tv/                    # preserved contents
│       └── music/                 # preserved contents
└── mister/                        # unchanged (peer of library/)
    └── games/
        ├── SNES -> ../../library/software/console/Nintendo - Super Nintendo Entertainment System/
        ├── GBA  -> ../../library/software/console/Nintendo - Game Boy Advance/
        └── …    # operator-maintained symlinks; MISTer follows via mfsymlinks over SMB
```

Future siblings under `staging/` (e.g. `staging/torrents/`, `staging/usenet/`)
are anticipated but not created by this plan — they materialize when a
specific downloader is wired up. YAGNI on empty parents.

## §1 — Why bundle the staging rename with the games restructure

These are conceptually independent but adjacent in the tree, and both
require operator-side migration on liberl. Doing them in one PR avoids
two separate cutover windows.

### Why `staging/` (vs the current flat `manual/`)

`manual/` collapses two ideas: "this is the input/staging tree" and
"this content arrived manually." The first is the durable
distinction; the second is just one of several arrival methods.
Renaming the parent to `staging/` and demoting `manual/` to one
sibling clarifies the model:

```
staging/
├── manual/        # rsync, scp, hand-organized
├── torrents/      # future — qBittorrent / *arr download client
├── usenet/        # future — sabnzbd / nzbget
└── …              # future — Syncthing receive folder, etc.
```

Each method has its own permissions/ownership posture (e.g. a
downloader's user typically writes only to its own subdir). The
parent provides a single conceptual boundary — "anything in
`staging/` is unverified; nothing here is canonical until something
moves it to `library/`."

### Why drop the `-hq` suffix on the inner directory under `staging-hq/`

Currently `manual-hq/` carries the tier suffix because it sits at the
top level next to `manual/`. Once nested under `staging-hq/`, the
parent already signals tier; an inner `manual-hq/` would double-name
it. So `staging-hq/manual/`, not `staging-hq/manual-hq/`.

This breaks symmetric naming with the existing `library-hq/` (which
keeps its suffix), but the asymmetry is honest: `library/` and
`library-hq/` are flat at the top level (tier is the only
distinguisher); `staging/` and `staging-hq/` have an inner method
layer where the tier suffix is redundant.

## §2 — Why the games-tree split

### The split is honest about lifecycle

The new layout makes ingest-pipeline distinctions operationally visible:

| Tree       | Source                  | Verifiable     | Reproducible from inputs?      | IGDB metadata likely?   |
| ---------- | ----------------------- | -------------- | ------------------------------ | ----------------------- |
| `console/` | DAT-driven (Igir)       | yes (DAT hash) | yes — re-run Igir              | yes (commercial titles) |
| `pc/`      | Manual (installer/dump) | no             | no — operator-curated artifact | sometimes               |

That table maps directly to "can I delete this and re-derive it?"
backups, audit, and replay questions. Mirroring it in storage keeps the
distinction load-bearing instead of relying on operator memory.

Romhacks (patched / community ROMs) live inside `console/` under
Igir's `{type}` token (e.g. `Hacks/`, `Translated/`) rather than in a
separate content root. This collapses the canonical-vs-derivative
distinction into one platform tree, which is accurate: a fan
translation of a SNES game belongs alongside the retail SNES library,
not in a separate namespace that breaks emulator configuration and
MISTer core selection. The `{type}` subdir makes the distinction
visible without requiring a separate Retrom content root or platform
identity split.

### Why PC is folder-per-game

Each PC title is a directory of installer/binary files. `MULTI_FILE_GAME`
storage type expects exactly that shape: each direct child of `pc/` is
one game, contents inside are operator-discretion (installer,
extracted tree, both). Trivially compatible with current operator
workflow.

### Why no Windows/Linux split under `pc/`

The original plan kept these separate. In Retrom's model, OS is a
property of the **Emulator/Launcher**, not the platform tree (see
`Emulator.operating_systems` in the proto — `WINDOWS`, `MACOS`,
`LINUX_x86_64`, `WASM`). Two trees gave us nothing the emulator config
doesn't already express, and forced operator decisions at staging time
that the desktop client can resolve at launch time. Collapsed to one
`pc/` tree.

### Why MISTer stays a peer of `library/`

The deployed `hosts/liberl/nas.nix` already places MISTer at
`/data/media/mister/`, peer to `/data/media/library/` — diverging
from the original plan's nested placement. That divergence is
intentional and matches what we want: MISTer's case-sensitive core-dir
naming (`SNES`, `Gameboy`, `MegaDrive`) is alien to the rest of the
library's conventions, and a peer placement keeps MISTer's bespoke
world separate from "the canonical, retrom-facing organized library."
Hardlinks from `library/software/console/<platform>/` to `mister/games/<Core>/`
are within-dataset (`data/media`) and remain free.

**No change to MISTer's location** — keep `/data/media/mister/games/<Core>/`
as deployed.

## §3 — Storage layout changes

### `hosts/liberl/nas.nix` tmpfiles

Replace the flat `manual/` and `manual-hq/` entries with their new
nested form, and replace the single `library/games` entry with the
software/console + software/pc tree. Note: no `library/software/romhacks`
— romhacks live under `console/<platform>/Hacks/` via Igir's `{type}` token.
Also add `mfs symlinks = yes` to the Samba `media` share for MISTer
symlink support.

Diff against current:

```nix
# Remove (flat manual/manual-hq + old games tree)
(dir "/data/media/manual")
(dir "/data/media/manual/movies")
(dir "/data/media/manual/tv")
(dir "/data/media/manual/music")
(dir "/data/media/manual-hq")
(dir "/data/media/manual-hq/movies")
(dir "/data/media/manual-hq/tv")
(dir "/data/media/manual-hq/music")
(dir "/data/media/manual/games")
(dir "/data/media/library/games")

# Add (staging/manual + staging-hq/manual; library software tree)
(dir "/data/media/staging")
(dir "/data/media/staging/manual")
(dir "/data/media/staging/manual/movies")
(dir "/data/media/staging/manual/tv")
(dir "/data/media/staging/manual/music")
(dir "/data/media/staging/manual/console")
(dir "/data/media/staging/manual/romhacks")
(dir "/data/media/staging/manual/pc")
(dir "/data/media/staging-hq")
(dir "/data/media/staging-hq/manual")
(dir "/data/media/staging-hq/manual/movies")
(dir "/data/media/staging-hq/manual/tv")
(dir "/data/media/staging-hq/manual/music")
(dir "/data/media/library/software")
(dir "/data/media/library/software/console")
(dir "/data/media/library/software/pc")

# Unchanged
(dir "/data/media/library")
(dir "/data/media/library/movies")
(dir "/data/media/library/tv")
(dir "/data/media/library/tv-curated")
(dir "/data/media/library/music")
(dir "/data/media/library-hq")
(dir "/data/media/library-hq/movies")
(dir "/data/media/library-hq/tv")
(dir "/data/media/library-hq/music")
(dir "/data/media/mister")
(dir "/data/media/mister/games")
```

Per-platform and per-type dirs under `console/` are not declared —
Igir creates them on demand, inheriting the parent's `2775 media:media`
setgid mode. `staging/manual/romhacks/` is retained as the operator
drop zone; content moves from there to `console/<platform>/Hacks/`.

### Why split the staging tree too

`manual/games/` was a single bucket. Splitting to
`staging/manual/{console,romhacks,pc}/` keeps each ingest workflow
visually distinct and makes "is this verified yet?" answerable by
directory. The staging side retains `romhacks/` as a named drop zone
even though the library side folds hacks into `console/` via `{type}`.

## §4 — Retrom configuration

### `hosts/calvard/microvm/guests/oracion/modules/retrom.nix`

Two `contentDirectories` entries: one for `console/` (CUSTOM, 4-level
definition) and one for `pc/` (MULTI_FILE_GAME). No separate romhacks
root — romhacks live inside `console/` under the Igir-assigned `{type}`
subdir. NFS mount point on oracion is `/media/`, matching the existing
convention. Retrom only sees the canonical `library/` tree; staging is
not exposed to Retrom.

```nix
contentDirectories = [
  # Console ROMs: platform/{type}/{gameDir} layout. {type} comes from
  # Igir's DAT metadata (e.g. "Retail", "Hacks", "Translated"). All
  # game types — official and romhacks — live under one content root;
  # the type level keeps them distinct within each platform.
  {
    path = "/media/library/software/console";
    storageType = 2; # CUSTOM
    customLibraryDefinition = {
      definition = "{library}/{platform}/{type}/{gameDir}";
    };
  }
  # PC games: folder-per-game, no platform layer. OS is resolved at
  # launch by Emulator.operating_systems, not by directory layout.
  {
    path = "/media/library/software/pc";
    storageType = 1; # MULTI_FILE_GAME
  }
];
```

mister/ is a sibling of library/ at `/media/mister`, outside all
scanned roots — no `ignorePatterns` entry needed.

### Why a 4-level definition works

Retrom's custom path parser tokenises any `{name}` in curly braces at
each `/`-delimited level and assigns the last token `{gameDir}`. The
`games_as_grandchildren()` test in `crates/core/src/game_scanner/`
confirms that depth-4 definitions resolve correctly. `{type}` is an
arbitrary token name — Retrom passes its value through as a string and
uses it only to populate `Platform.path` metadata; it does not need to
match a reserved keyword.

## §5 — Ingestion workflow updates

These are operator-runbook changes only; no Nix-side path
references to update.

### Console ROMs (Igir, DAT-driven) — staging + library paths both change

```
# Before
igir copy extract test clean \
    --input  /media/manual/games/<platform>/ \
    --output /media/library/games \
    ...

# After
igir copy extract test clean \
    --input  /media/staging/manual/console/<platform>/ \
    --output /media/library/software/console \
    --dat    <path-to-dat> \
    ...
```

Igir writes each game into
`/media/library/software/console/<platform>/<type>/<gameDir>/`
where `<type>` (e.g. `Retail`, `Hacks`, `Translated`) comes from the
DAT category for that ROM. No extra flags needed — the output template
uses `{type}` automatically.

The MISTer workflow changes from an Igir link pass to operator-maintained
symlinks. Instead of running `igir link`, the operator creates one symlink
per core in `mister/games/` pointing at the platform dir:

```bash
# One-time setup per platform, run on liberl (or bose as mediaops)
ln -s ../../library/software/console/Nintendo\ -\ Super\ Nintendo\ Entertainment\ System \
      /data/media/mister/games/SNES
ln -s ../../library/software/console/Nintendo\ -\ Game\ Boy\ Advance \
      /data/media/mister/games/GBA
# … etc for each core
```

MISTer follows these symlinks over SMB (the `media` share has
`"mfs symlinks" = "yes"` in `nas.nix`). The MISTer CIFS client must
also have `mfsymlinks` in its `cifs_mount.ini`:

```ini
[share]
server=liberl
share=media
mountpoint=/media/fat
options=mfsymlinks
```

MISTer then sees `mister/games/SNES/` containing `Retail/`,
`Hacks/`, etc. — all navigable from its file browser.

### Romhacks (manual, operator-curated)

Romhacks now go into `console/<platform>/Hacks/<HackTitle>/` rather
than a separate library tree. Workflow:

1. Operator drops patched ROM (IPS-applied output) under
   `/media/staging/manual/romhacks/<platform>/<HackTitle>/`.
2. On bose, as `mediaops`:
   ```bash
   mv /media/staging/manual/romhacks/snes/<HackTitle> \
      /media/library/software/console/Nintendo\ -\ Super\ Nintendo\ Entertainment\ System/Hacks/
   ```
3. Retrom rescan picks it up under the SNES platform's `Hacks` type.
   Metadata will be sparse (IGDB doesn't index most hacks); operator
   can edit names/cover art in the Retrom UI per game.

`staging/manual/romhacks/` is retained as the named drop zone even
though the library side folds hacks into `console/` — it keeps the
ingest workflow visually distinct from DAT-verified ROMs.

### PC games (manual) — staging + library paths both change

```
# Before
mv /media/manual/games/windows/<incoming>/<MyGame> \
   /media/library/games/windows/<MyGame>/

# After
mv /media/staging/manual/pc/<incoming>/<MyGame> \
   /media/library/software/pc/<MyGame>/
```

No Windows/Linux split at the staging tier either — drop everything
under `staging/manual/pc/`.

### Movies / TV / music (existing arr pipeline) — staging path change only

The arr stack reads from `/media/manual/{movies,tv,music}/` and
`/media/manual-hq/{movies,tv,music}/` today. After the rename:

| Tier    | Old staging path           | New staging path                   |
| ------- | -------------------------- | ---------------------------------- |
| Default | `/media/manual/movies/`    | `/media/staging/manual/movies/`    |
| Default | `/media/manual/tv/`        | `/media/staging/manual/tv/`        |
| Default | `/media/manual/music/`     | `/media/staging/manual/music/`     |
| HQ      | `/media/manual-hq/movies/` | `/media/staging-hq/manual/movies/` |
| HQ      | `/media/manual-hq/tv/`     | `/media/staging-hq/manual/tv/`     |
| HQ      | `/media/manual-hq/music/`  | `/media/staging-hq/manual/music/`  |

Library output paths are unchanged (`/media/library/{movies,tv,music}/`,
`/media/library-hq/{movies,tv,music}/`).

Sonarr/Radarr/Lidarr each store their own root-folder and
manual-import paths in their SQLite databases (runtime config, not
Nix). After the rename, the operator must update the Manual Import
path setting in each app's UI on bose and ravennue:

- ravennue Sonarr/Radarr/Lidarr: `/media/manual/...` → `/media/staging/manual/...`
- bose Sonarr/Radarr/Lidarr: `/media/manual-hq/...` → `/media/staging-hq/manual/...`

filebot-ingest and any other shell wrappers that bake in staging
paths also need updating. See §7 for the full doc-update list.

## §6 — Migration

One-shot operator step on liberl. Run as `mediaops` (or root, with care
to preserve `media:media` ownership). Order matters: rename top-level
trees first, then split the games subtree, then deploy nas.nix
(tmpfiles materializes any missing dirs and is idempotent).

```bash
# On liberl
sudo -u mediaops bash <<'EOF'
set -euo pipefail
umask 0002
cd /data/media

# ── Stage 1: top-level rename (manual → staging/manual, manual-hq → staging-hq/manual)
mkdir -p staging staging-hq
if [ -d manual ]; then
  mv manual staging/manual
fi
if [ -d manual-hq ]; then
  mv manual-hq staging-hq/manual
fi

# ── Stage 2: split games subtree under library/software/
mkdir -p library/software/{console,pc}
# Console — straight rename
if [ -d library/games/consoles ]; then
  mv library/games/consoles/* library/software/console/ 2>/dev/null || true
  rmdir library/games/consoles
fi
# PC — collapse windows + linux into software/pc/
if [ -d library/games/windows ]; then
  mv library/games/windows/* library/software/pc/ 2>/dev/null || true
  rmdir library/games/windows
fi
if [ -d library/games/linux ]; then
  mv library/games/linux/* library/software/pc/ 2>/dev/null || true
  rmdir library/games/linux
fi
# library/games/ should now be empty (mister was always at /data/media/mister)
rmdir library/games 2>/dev/null || true

# ── Stage 3: split games subtree under staging/manual/
mkdir -p staging/manual/{console,romhacks,pc}
if [ -d staging/manual/games ] && [ "$(ls -A staging/manual/games)" ]; then
  echo "WARNING: staging/manual/games has content. Move by hand to"
  echo "         staging/manual/{console,romhacks,pc}/ then rmdir."
  ls -la staging/manual/games
else
  rmdir staging/manual/games 2>/dev/null || true
fi
EOF
```

**Name-collision risk in pc/**: if both `windows/<Game>` and
`linux/<Game>` exist (same title, multiple platforms), the second `mv`
will refuse. Operator-resolves by renaming or merging directories
manually before running the migration block.

After migration succeeds, deploy the updated `nas.nix` (tmpfiles takes
over from there). On the guest hosts (bose, ravennue, oracion) the
virtiofs-mounted `/data/media` will reflect the new tree
automatically — no guest-side migration needed.

### Retrom platform cleanup

Old `contentDirectories` produced a "games" content-root in Retrom's
DB. After the new config deploys, Retrom on first scan will:

- Discover two new content roots (software/console/, software/pc/).
- Mark games under the old `games/` root as missing (because that path
  no longer exists).

Operator step: in Retrom's web UI, clean up orphaned platforms/games
under the old root. Retrom's "Clean Library" modal handles this
(`packages/client-web/src/components/modals/clean-library/`). Confirm
the old root is removed before clicking.

If clean-library doesn't fully drop the old root entry, a Postgres
delete from `retrom-db` is the fallback (`DELETE FROM platforms WHERE
path LIKE '/media/library/games/%'`) — document in the runbook only if
it actually proves necessary.

### Arr stack reconfiguration

For each Sonarr/Radarr/Lidarr instance on bose and ravennue, after
the rename:

1. Manual Import paths: change `/media/manual*/...` →
   `/media/staging/manual/...` (default tier) or
   `/media/staging-hq/manual/...` (HQ tier).
2. Any saved Custom Scripts or path mappings that reference the old
   paths.
3. Post-import script paths (filebot-ingest invocations, if any).

This is point-and-click in each app's settings UI — no DB surgery
needed. Library Folders (output side) are unchanged.

## §7 — Documentation updates

The active runbook and spec mention `manual/` paths heavily. Update in
the same PR:

- **`llm-notes/guides/media-ingestion-runbook.md`** — operator runbook.
  Path table (§ near line 620) and all `mv`/`ls`/`rsync` examples
  reference `/media/manual/...` and `/media/manual-hq/...`. Replace
  systematically with the new staging paths.
- **`llm-notes/specs/jellyfin-media-organization.md`** — design spec.
  Tree diagrams and prose mention the flat `manual/` / `manual-hq/`
  layout; update to show `staging/manual/` and `staging-hq/manual/`.
- **`llm-notes/reports/self-hosting-recommendations.md`** — references
  `/data/media/manual/` as the Syncthing target; update to
  `/data/media/staging/manual/` (or note Syncthing should land in a
  future `staging/syncthing/` sibling, depending on intent).

`done/` plans (`retrom-game-pipeline.md`,
`media-ingestion-runbook.md`, `ravennue-instance.md`,
`music-stack-plan.md`, `media-organization-pipeline.md`) describe the
state at the time they shipped. Per CONVENTIONS.md, prefer adding a
top-of-file "Successor: …" pointer rather than rewriting them. They
remain accurate as historical record.

## §8 — Implementation order

One PR, with the operator-side migration sequenced before deploy.

### PR — restructure + rename

1. [x] `hosts/liberl/nas.nix`: replace tmpfiles entries per §3.
2. [x] `hosts/calvard/microvm/guests/oracion/modules/retrom.nix`: replace
   `contentDirectories` per §4.
3. `llm-notes/guides/media-ingestion-runbook.md`: update path
   references per §7.
4. `llm-notes/specs/jellyfin-media-organization.md`: update tree
   diagrams per §7.
5. `llm-notes/reports/self-hosting-recommendations.md`: update path
   references per §7.
6. `nix fmt && ./scripts/run-checks.sh`.
7. **Before deploying**: run §6 migration on liberl as a one-shot.
   Confirm `/data/media/{manual,manual-hq,library/games}` are gone,
   and the new trees exist with content moved correctly.
8. Deploy liberl (tmpfiles materializes any missing dirs;
   idempotent if they already exist from migration).
9. Deploy calvard/oracion (Retrom picks up the new
   `contentDirectories`).
10. **Arr-stack reconfiguration** per §6 — update Manual Import paths
    in each Sonarr/Radarr/Lidarr instance on bose and ravennue.
11. **First-scan verification** (§9).
12. Update `llm-notes/done/retrom-game-pipeline.md` with a postscript
    pointing to this plan.
13. Move this plan from `wip/` to `done/` once shipped.

The migration block is the operationally risky bit (mv invocations
that touch all the user's media). Doing it before deploying the new
Nix means tmpfiles won't pre-create empty target dirs that confuse
the moves.

## §9 — Test plan

Operational, no test harness. Per-PR checks after deploy:

1. **Liberl**:
   - `ls /data/media/staging/manual/{movies,tv,music,console,romhacks,pc}/` — all exist, mode `2775`, owned `media:media`.
   - `ls /data/media/staging-hq/manual/{movies,tv,music}/` — all exist, mode `2775`, owned `media:media`.
   - `ls /data/media/library/software/{console,pc}/` — both exist, mode `2775`, owned `media:media`. No `romhacks/` sibling.
   - `/data/media/{manual,manual-hq,library/games}` do not exist.
   - `mister/games/` has the operator-created symlinks; verify one: `readlink /data/media/mister/games/SNES` → `../../library/software/console/Nintendo - Super Nintendo Entertainment System`.
2. **Bose / ravennue**: from `mediaops`, write to
   `/media/library/software/{console,pc}/` and
   `/media/staging/manual/...` and `/media/staging-hq/manual/...`
   succeeds (NFS RW path).
3. **Oracion**: `systemctl status retrom postgresql` healthy. Retrom's
   logs show successful scan of two new content roots.
4. **Retrom UI**: browse to `https://retrom.internal/`, confirm:
   - Two new content roots present in server config (console/, pc/).
   - Old `games/` root is absent (or marked for cleanup).
   - Console games surface under their platform names, with type subdirs
     (`Retail/`, `Hacks/`, etc.) visible per platform.
   - PC games surface as one platform (the implicit `pc` content root).
5. **Arr stack**: in each Sonarr/Radarr/Lidarr instance, Manual Import
   from the new staging path succeeds; library hardlink still works
   (verify cross-tree inode sharing with `ls -li`).
6. **MISTer over SMB**: from MISTer, confirm `mister/games/SNES/`
   resolves the symlink and lists the platform contents (both `Retail/`
   and `Hacks/` are visible). Confirm `mfsymlinks` is present in
   MISTer's `cifs_mount.ini` before testing.
7. **Cross-VLAN**: from a workstation, `getent hosts retrom.internal`
   resolves; web client loads, scans new tree.

## §10 — Notes / non-blocking

- **Future `staging/` siblings.** When a downloader (Syncthing,
  qBittorrent, sabnzbd) is wired up, it lands under `staging/` as its
  own sibling (`staging/syncthing/`, `staging/torrents/`,
  `staging/usenet/`). Each gets its own user/group write posture; the
  `staging/` parent is the conceptual boundary, not a permissions
  boundary.
- **Romhack DAT support.** If romhack scenes ever produce usable DATs
  (rare — the SMW Central / Hardcore community tools mostly produce
  patches, not DATs), Igir can ingest into `console/<platform>/Hacks/`
  the same way it ingests commercial DATs, just pointing at a different
  DAT file. The type token handles it — no directory restructuring
  needed. Worth revisiting if/when a specific hack scene ships a DAT.
- **MISTer symlink maintenance.** The `mister/games/<Core>/` symlinks
  are operator-maintained. When a new platform is added to the console
  library, the operator creates a new symlink in `mister/games/` using
  the MISTer core name. No Igir link pass is needed. The `mfsymlinks`
  Samba option (already set in `nas.nix`) is required for MISTer to
  follow these symlinks; the MISTer client also needs `mfsymlinks` in
  `cifs_mount.ini` (see §5).
- **Liberl SMB share.** SMB share `media` exposes `/data/media/`
  with `"mfs symlinks" = "yes"` (added in this plan). Windows clients
  see the renamed top-level dirs automatically; the mfsymlinks option
  is a no-op for Windows (which uses its own symlink protocol) but
  required for MISTer's Linux CIFS client.
- **Original plan's `games/` naming.** `done/retrom-game-pipeline.md`
  remains as a historical record of how the games pipeline was first
  built. After this plan ships, add a postscript pointing to this
  plan, since the on-disk layout now diverges from what that plan
  describes.
