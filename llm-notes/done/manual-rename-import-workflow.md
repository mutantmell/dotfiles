# Plan: manual rename + Library Import + Rename Files workflow

> **Status:** Implemented. Runbook §3/§4 have been updated to the
> three-step shape described here. Subsequently, the pre-rename tool
> was switched from `mnamer` to `FileBot` (better multi-episode and
> alternate-ordering support); the workflow shape is unchanged. See
> `llm-notes/guides/media-ingestion-runbook.md` §3 for current
> commands. References to `mnamer` below are historical.

## Goal

Replace the broken adopt-in-place Library Import workflow in
`media-ingestion-runbook.md` §4 with a uniform three-step shape that
works the same way across every arr-supported media type:

```
1. Pre-rename tool writes to /media/library/<type>/   (mnamer for video)
2. arr Library Import wizard adopts what's already there
3. arr Mass Edit → Rename Files applies MediaInfo-rich TRaSH naming
```

Steps 1 and 3 are bulk operations across a batch; step 2 is a one-time
wizard click-through per batch. End state: `library/` contains the
canonical hardlinkable tree, fully tracked by the appropriate arr,
named with the full MediaInfo-aware TRaSH scheme that distinguishes
4K/HDR/codec/audio/release-group.

## Why this shape (over the auto-import alternative we discarded)

The previously-considered approach was a liberl-side inotify watcher
that POSTed `DownloadedMoviesScan`/`DownloadedEpisodesScan` to bose on
file arrival. That works, but:

- It only solves video (Radarr/Sonarr). Music has no equivalent (no
  Lidarr deployed); audiobooks/ebooks won't either until the
  corresponding arr is in place. Each new media type needs its own
  watcher branch.
- It introduces a new long-lived service, sops-managed API keys, a
  cleanup pass, and a virtiofs-vs-inotify-aware deployment story
  (watcher must run on the writer host).
- The user's bar was a uniform workflow across all media types. Three
  click-through steps that are _the same shape everywhere_ beats one
  hands-off pipeline that only covers video.

The trade-off accepted: ~3 manual steps per batch (pre-rename → import
wizard → rename button) instead of zero. Acceptable for at-the-keyboard
digitization of physical media.

## Why writing to library/ directly works

mnamer (and the eventual music/ebook equivalents) only have to produce
something **parseable** in `library/`. They don't need to produce the
final TRaSH name — that's what step 3 is for. So mnamer writes
`Title (Year)/Title (Year).ext`, Library Import adopts it in place, and
then **Mass Edit → Rename Files** with `Rename Movies: ON` and
`Analyze video files: ON` rewrites every file to the full
`Foo (2024) [Bluray-2160p][HDR][HEVC]-RG.mkv` form.

`Analyze video files: ON` is the load-bearing setting. Without it,
Radarr/Sonarr take quality/codec/HDR from the filename via guesses
rather than from MediaInfo on the actual stream. mnamer's filenames
don't carry that info, so without analysis the rename produces
generic names (`Foo (2024) [Unknown].mkv`). With analysis on, Radarr
probes the file and synthesizes the full MediaInfo block.

This is currently OFF by default in both Radarr and Sonarr; the runbook
needs to flip it.

## Hardlinks still happen

The "Use Hardlinks: ON" setting (already in §1.2/§1.3) governs what
happens when an arr **moves** files between root folders or applies a
rename. Library Import is adopt-in-place, but the subsequent **Rename
Files** pass writes a new filename in the same dataset — that's a
rename, which is hardlink-cheap by nature. End state is the same as
the auto-import path: one file in `library/`, no orphans in `manual/`
because mnamer wrote straight into `library/` (skipping `manual/`
entirely for ingestion).

`manual/` is no longer the ingestion lane in this design. It's reserved
for cases where someone wants to stash files temporarily before
deciding where they go. (Could be deleted from the spec entirely; left
in place for now to avoid an unrelated tmpfiles change.)

## Per-type pre-rename tools

| Type   | Tool       | Status                                                   |
| ------ | ---------- | -------------------------------------------------------- |
| Movies | `filebot`  | In `arr.nix` (replaced mnamer); `filebot-ingest` on PATH |
| TV     | `filebot`  | In `arr.nix` (replaced mnamer)                           |
| Music  | (deferred) | No Lidarr deployed; pick `beets` or `picard` when adding |
| Books  | (deferred) | No Readarr deployed; pick when adding                    |

Music and books are out of scope for this plan. They share the same
**workflow shape** when their arrs ship — the pre-rename tool changes,
but Library Import + Mass Edit Rename are uniform across the arr
ecosystem. Document the shape; instantiate per type as the arrs come
online.

## Components to change

### 1. `media-ingestion-runbook.md` §1.2 (Sonarr first-run)

Under **Settings → Media Management → File Management**:

> - **Analyze video files**: ON
> - **Set Permissions**: OFF

`Analyze video files`: required so MediaInfo tokens (`{Mediainfo VideoCodec}`
etc.) populate during Rename Files; without it Sonarr falls back to
filename guessing, which mnamer's outputs don't carry.

`Set Permissions`: OFF, because the chmod/chown attempt fails with
EPERM. mnamer creates files owned by the operator's user (not
`media`), `rename(2)` preserves owner across rename, and Sonarr-as-
`media` can't `chown()` to a different uid (no CAP_CHOWN) or `chmod()`
a file it doesn't own. Worse, the runbook's previously-recommended
`chmod 755/644` strips group-write, which would re-break the next
rename. The filesystem layer (mnamer-ingest's `umask 0002` +
`nas.nix:62`'s setgid 2775 parents) already produces `2775` dirs and
`0664` files with `group=media` — exactly what we want — so Sonarr
doesn't need to touch perms at all. Drop the `chmod 755/644` and
`chown media:media` sub-bullets entirely.

### 2. `media-ingestion-runbook.md` §1.3 (Radarr first-run)

Same additions: **Analyze video files: ON** and **Set Permissions: OFF**
under File Management. Drop the `chmod 755/644, chown media:media`
sub-bullet. Same rationale as §1.2.

### 3. `media-ingestion-runbook.md` §3 (mnamer)

Retarget mnamer to write **into `/media/library/<type>/`** rather than
`/media/manual/<type>/`. Concretely:

```bash
# Movies — dry run first
mnamer-ingest --movie-directory=/media/library/movies \
              --movie-format='{name} ({year})/{name} ({year}).{extension}' \
              --test \
              /media/manual/movies/    # source: where the raw files came in

# Real run
mnamer-ingest --movie-directory=/media/library/movies \
              --movie-format='{name} ({year})/{name} ({year}).{extension}' \
              /media/manual/movies/
```

The `--movie-directory` flag tells mnamer where to **write** the
organized output; it can pull sources from anywhere. Equivalent for
TV via `--episode-directory=/media/library/tv`.

**Why `mnamer-ingest` and not bare `mnamer`**: the wrapper (defined in
`bose/modules/arr.nix`) sets `umask 0002` before invoking mnamer. The
NFS-exported `library/<type>/` parents are `2775` (setgid, group=media)
via `nas.nix:62`, which makes new subdirs inherit `group=media` — but
the setgid bit does **not** propagate group-write; that comes from the
process umask. With the default `0022`, mnamer creates dirs at `0755`,
so Radarr-as-`media` can't rename within them later (EACCES on the
parent dir). `umask 0002` produces `0775` dirs and `0664` files, which
combined with setgid gives the chain Radarr expects.

Update the "What mnamer owns vs. what Radarr owns" prose: mnamer now
writes the _parseable scaffold_ directly into `library/`; Radarr's
canonical TRaSH naming is applied via the Rename Files step in §4, not
via Library Import.

### 4. `media-ingestion-runbook.md` §4.1 (Radarr workflow)

Rewrite as a three-step shape:

1. **Library Import** (`/add/import`, folder
   `/media/library/movies`) — Radarr adopts everything mnamer wrote.
   Set quality profile + monitored state per row, click Import.
2. **Movies → select all → Mass Edit → Rename Files**. Radarr applies
   the §1.3 TRaSH format to every adopted file. Because
   `Rename Movies: ON` and `Analyze video files: ON` are set, the
   resulting filenames carry full MediaInfo metadata.
3. **Verify** by spot-checking a row's filename in the UI and on disk;
   confirm Connect fired (Jellyfin Activity).

Drop the "import from `/media/manual/movies`" step entirely — manual/
is no longer the ingestion path for this workflow.

Drop the §4.3 cleanup pass (the `find -delete` over manual/) — there
is nothing in `manual/` to clean up because mnamer wrote into
`library/` directly.

### 5. `media-ingestion-runbook.md` §4.2 (Sonarr workflow)

Same shape, with `/media/library/tv` and Sonarr's Mass Edit → Rename.

### 6. `media-ingestion-runbook.md` Troubleshooting

- Remove the "Library Import says 'all movies have been imported'"
  entry's premise of dropping into `manual/`. Re-shape it: the same
  failure mode (loose files in folder root) still happens if mnamer
  hasn't been run; the guidance is the same — run mnamer with the
  folder-creating format.
- Add a note: if Rename Files produces names like
  `Foo (2024) [Unknown].mkv`, Analyze Video Files is OFF — go enable
  it, then re-run Mass Edit → Rename Files.
- Keep the EXDEV note (still relevant: `library/` must be one ZFS
  dataset).
- Remove or revise the "Library Import broken" framing entirely: the
  workflow now uses Library Import correctly (as adopt-in-place) with
  Rename as the second step.

## What's explicitly NOT changing

- `arr.nix` — no NixOS module changes. mnamer stays on bose, the arr
  service definitions stay as-is. `Analyze video files: ON` is a
  Radarr/Sonarr UI setting stored in `config.xml`, not declared in
  Nix.
- `sops.nix` / API keys — no new secrets needed; we're not POSTing to
  Radarr/Sonarr from outside.
- `bose/default.nix` egress filter — unchanged.
- Phase 0/Phase 5/Phase 6 of the runbook — unchanged.

## Test plan

Operational, no NixOS test harness:

1. Apply the §1.2/§1.3 setting in the live Radarr/Sonarr UIs (or
   note them for the next first-run).
2. Stage one test movie: `rsync` to
   `liberl:/data/media/manual/movies/raw/Test.2024.1080p.mkv`.
3. From bose: run mnamer with the new `--movie-directory=/media/library/movies`
   form against the raw drop. Verify
   `/media/library/movies/Test (2024)/Test (2024).mkv` exists.
4. In Radarr: Library Import → folder `/media/library/movies` → Import.
5. Movies → select all → Mass Edit → Rename Files. Verify the file is
   renamed to `Test (2024) [Bluray-1080p][...]-RG.mkv` (MediaInfo
   tokens populated).
6. Spot-check on disk via `ls -li`: same inode as before the rename
   (rename within a dataset is link-preserving).
7. Confirm Jellyfin scan was triggered (Activity log on oracion).
8. Repeat shape for one TV episode in Sonarr.

## Open questions / followups (not blocking)

- **Music/Readarr arrs** — when deployed, instantiate the same
  three-step shape with `beets` or `picard` (music) / `Calibre` or
  hand-rename (books) as the pre-rename tool.
- **`manual/` retirement** — if `manual/` truly never sees a write
  again, the tmpfiles entries in `nas.nix` could be removed. Defer
  until usage shows it's actually unused.
- **mnamer output collisions** — the `{name} ({year})` template
  collides if both 4K and 1080p of the same movie are processed in
  one batch. Workaround: stage them in separate runs, or extend
  mnamer's format to include a quality token. Once Radarr's TRaSH
  rename runs, the canonical filenames carry quality so collisions
  go away — but mnamer writes first, so it has to not collide. Likely
  fine in practice (most batches are one quality each); revisit if
  it bites.
