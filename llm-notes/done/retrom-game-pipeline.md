# Plan: Games library + game pipeline (Retrom + Igir + MISTer)

## Goal

Add the third media-type leg to the existing pipeline: **games**, of
which ROMs are one subtype. Same shape as video and music — RW
ingestion on the NAS-side arr host (bose), RO serving from the
calvard-side serving guest (oracion). Retrom is a general-purpose
self-hosted game library (think "self-hosted Steam for DRM-free
games"), not a ROM-specific tool — it's well-suited to managing
Windows games, native Linux games, and console ROMs side by side
through a single client.

End state — four content kinds in the library:

| Kind                     | Producer (RW)            | Destination (RO)                     | Surfaced via      |
| ------------------------ | ------------------------ | ------------------------------------ | ----------------- |
| Console ROMs             | Igir on bose, DAT-driven | `library/games/consoles/<platform>/` | Retrom            |
| Windows games            | operator on bose, manual | `library/games/windows/<Title>/`     | Retrom            |
| Native Linux games       | operator on bose, manual | `library/games/linux/<Title>/`       | Retrom            |
| MISTer FPGA view of ROMs | Igir link mode on bose   | `library/games/mister/...`           | MISTer (CIFS/SMB) |

Single tier (no `library-hq/games/`) — games don't carry a
quality-tier split. One canonical artifact per title is the goal.

## §0 — Where we are, why this is the next step

Phases 1–6 of `plans/media-organization-pipeline.md` are deployed
(liberl reformat, NFS hardening, bose arr stack, calvard/Jellyfin
fixes). All three music-stack PRs are in (`library-hq/` rename, Lidarr
on bose+ravennue, Navidrome on oracion).

Of the spec's "Future Goals", the three serious candidates are
**Unmanic encoding** (deferred — Steam Deck LCD's Van Gogh APU has
AV1 decode but no AV1 encode; software SVT-AV1 on that silicon
isn't worth the runtime), **Audiobookshelf** (small, Navidrome-shape),
and **Retrom** (this plan). Games add a new media type with a
genuinely new client surface (desktop client + web client + FPGA
hardware via CIFS) and exercise the pipeline for non-streaming
artifacts — strictly larger architectural progression than another
RO streaming reader.

## §1 — Tool choice: Retrom + Igir

### Retrom (server) — replaces RomM in the original spec

The spec at line 622 named **RomM** (AGPL3). It isn't packaged in
nixpkgs and its only client is browser-based EmulatorJS, which is
poor for anything past PS1 and (more importantly) is ROM-only —
it has no story for Windows or Linux games. **Retrom** (GPL3) is a
general-purpose game library: same conceptual role for games that
Jellyfin plays for video, with Windows/macOS/Linux desktop clients,
a web client, and an architecture that treats console ROMs as just
another "platform" alongside `pc-windows` / `pc-linux`. Upstream
ships its own [Nix flake](https://github.com/JMBeresford/retrom/blob/main/flake.nix)
with `nixosModules.retrom` (server) and `homeModules.retrom`
(desktop client), plus a cachix substituter.

**License note.** Retrom (GPL3) and RomM (AGPL3) are the only
serious self-hosted-server options in this niche; there is no
permissive comparable. Permissive frontends like ES-DE / Pegasus
are local-only with no server architecture, so don't compete on the
same axis. The user's permissive-license preference doesn't apply
when no comparable permissive tool exists.

**No EmulatorJS in-browser play.** Retrom expects a real client
(desktop or web client driving an external launch). Coverage
trade-off: better PS2/GameCube/Switch playback (real emulators on
the client), worse zero-install access. For this homelab that's
fine — clients are owned and known.

### Igir (ingestion, ROMs only) — already in nixpkgs, MIT

`pkgs.igir` is in nixpkgs (MIT). It does DAT-based verification
(No-Intro, Redump, MAME, FBNeo), canonical renaming, deduplication,
per-platform layout, and — critical for this plan — a built-in
**MISTer** output mode that maps platforms to MISTer's case-sensitive
core directory names. Same role for ROMs that FileBot/beets play for
video/music. Runs on bose, as `mediaops`, using the same
`umask 0002` wrapper pattern as `filebot-ingest` and `beets-ingest`.

Igir is **not** used for PC games (Windows / native Linux). Those
have no DAT-equivalent and no canonical-rename concept; they're
operator-organized with manual layout (see §4.2).

## §2 — Storage layout

Games sit alongside the other media types under both staging and
library trees. Single tier — no `manual-hq/games` /
`library-hq/games`.

```
/data/media/
├── manual/
│   └── games/
│       ├── windows/   ← RW staging — incoming Windows installers / extracted dirs
│       ├── linux/     ← RW staging — incoming Linux installers / extracted dirs
│       └── roms/      ← RW staging — raw / unverified ROM dumps before Igir
└── library/
    └── games/
        ├── windows/   ← organized PC-Windows library (Retrom platform)
        │   └── <Title>/
        ├── linux/     ← organized PC-Linux library (Retrom platform)
        │   └── <Title>/
        ├── consoles/  ← Igir-canonical ROM library (Retrom platforms)
        │   ├── gba/
        │   ├── gbc/
        │   ├── gb/
        │   ├── nes/
        │   ├── snes/
        │   ├── n64/
        │   ├── ps/
        │   ├── ps2/
        │   ├── gc/
        │   └── …      # platforms added on demand
        └── mister/    ← MISTer-shaped derived view (NOT a Retrom platform)
            ├── games/
            │   ├── NES/        # MISTer core dir names are case-sensitive
            │   ├── SNES/
            │   ├── Genesis/
            │   ├── PSX/
            │   └── …
            └── _Arcade/        # MRA + arcade ROM data, when arcade is in scope
```

### Why `consoles/` and `mister/` are sibling trees, not one with the other

**Two consumers, two layouts.** Retrom is layout-agnostic — its
content-directory model takes a `path` plus a `storage_type` of
`SINGLE_FILE_GAME` (0), `MULTI_FILE_GAME` (1), or `CUSTOM` (2,
with a macro string like `{library}/{platform}/{gameFile}`) — so
Retrom adapts to whatever per-platform dirnames we pick (`gba/`,
`snes/`, lowercase short codes). MISTer's firmware, by contrast,
reads ROMs from `/media/fat/games/<Core>/` where `<Core>` is a
case-sensitive name matching the loaded core (`Gameboy`, `SNES`,
`MegaDrive`, `PSX`, …) and is not configurable. The two naming
conventions are incompatible and we do not want to compromise
either consumer.

**Hardlinks, not copies.** `library/games/consoles/<platform>/`
is the canonical location — the actual ROM bytes live there,
verified and renamed by Igir. The MISTer view at
`library/games/mister/games/<Core>/` is generated as **hardlinks**
into the canonical tree. ZFS hardlinks within a single dataset are
free (single inode, two directory entries), give MISTer the
case-sensitive names it wants, and avoid double-storing a multi-GB
collection. Igir's dedicated `link` command supports
`--link-mode hardlink|symlink|reflink` (hardlink is the default),
so this is a first-class operation — not a workaround.

The `data/media` ZFS dataset is a single dataset with no children
(per `plans/media-organization-pipeline.md` Phase 1.5 — required
for hardlink support across `torrents/` ↔ `library/`). That same
property is what makes the MISTer hardlink view free.

**`mister/` is not a Retrom platform.** Configure Retrom to scan
`library/games/{windows,linux,consoles}/` and explicitly exclude
`library/games/mister/` from its content roots. Otherwise every
title appears twice — once in its real platform, once duplicated
under MISTer.

### What lives where

- **Console ROM bytes** (canonical) → `library/games/consoles/<platform>/`
- **Console ROMs MISTer-shaped** → `library/games/mister/games/<Core>/` (hardlinks)
- **MISTer arcade content** (MRAs + arcade ROMs) →
  `library/games/mister/_Arcade/`
- **Windows games** → `library/games/windows/<Title>/`
- **Linux games** → `library/games/linux/<Title>/`

### What does **not** live in the games library

- **MISTer cores / firmware (.rbf, .mra system files)** — these are
  software for the FPGA, not game data. Belong on the MISTer SD card
  or a dedicated CIFS share, not in `library/games/`.
- **MISTer save states / SRAM** — per-client mutable state. If
  network-shared at all, in a separate writable directory (TBD;
  not in scope here). Definitely not under the RO library tree.
- **Configs** (`MiSTer.ini`, `cifs.txt`, etc.) — per-device.
- **Steam libraries / DRM-bound content** — Retrom can bridge to a
  client's local Steam install, but the bytes don't live in the
  homelab library. Out of scope.

### Nix change — `hosts/liberl/nas.nix`

Add tmpfiles entries for the staging dirs and the top-level library
directories. Per-platform subdirectories under `consoles/` and
`mister/games/` materialize as Igir creates them; Igir respects the
parent's setgid bit (2775 → child dirs inherit `media:media`).

```nix
(dir "/data/media/manual/games")
(dir "/data/media/manual/games/windows")
(dir "/data/media/manual/games/linux")
(dir "/data/media/manual/games/roms")
(dir "/data/media/library/games")
(dir "/data/media/library/games/windows")
(dir "/data/media/library/games/linux")
(dir "/data/media/library/games/consoles")
(dir "/data/media/library/games/mister")
(dir "/data/media/library/games/mister/games")
```

Same `2775 media:media` mode as the rest. Don't pre-declare per-
platform leaf dirs — Igir + operator manual `mkdir` create them as
needed, and tmpfiles enforcing them adds noise.

## §3 — Retrom server on oracion (co-located, Navidrome-shape)

oracion already runs Jellyfin, Navidrome, and an nginx that fronts
both with basel-issued TLS. Adding Retrom is the same shape as
Navidrome: import upstream's `nixosModules.retrom`, add a
service-named vhost, persist one directory + Postgres data, no new
VM.

**Why co-locate, not a new microvm:**

- Identical threat model to Navidrome / Jellyfin — RO consumer of
  organized library, HTTPS metadata egress (IGDB/SteamGridDB).
- Retrom is small at idle (Rust binary, sub-100 MB RAM). Library
  scans are the only spike, and they're rare.
- One persist directory + one Postgres DB fit into oracion's
  existing impermanence story.
- nginx + ACME-on-basel already handle the cert flow.

Trade-off accepted: a Retrom bug or runaway scan can pressure
Jellyfin/Navidrome on the same guest. Mitigations match the music
plan §4 — `MemoryMax=` / `CPUQuota=` on the unit; split to a
dedicated guest if a real incident forces it.

### Flake input — `flake.nix`

```nix
inputs.retrom.url = "github:JMBeresford/retrom";
inputs.retrom.inputs.nixpkgs.follows = "nixpkgs";
```

Upstream exposes `retrom.cachix.org` as a substituter via
`nixConfig.extra-substituters`. Add it to this flake's
`nixConfig.extra-substituters` (and the public key to
`extra-trusted-public-keys`) so we don't rebuild Retrom from
source on every machine. Building from source still works as a
fallback.

### Wiring upstream's NixOS module into oracion

Microvm guests in this flake are loaded by `mk-microvm` (a passive
`mkMerge` over `commonModules`) — they're plain
`{config, pkgs, ...}: {...}` module functions and don't see flake
inputs directly. To make `retrom.nixosModules.retrom` reachable
from a guest module, expose it through an overlay so it lands on
`pkgs.mmell.*`, matching the existing `pkgs.mmell.lib.builders`
pattern:

```nix
# flake.nix overlays section — alongside the existing `lib` and
# `packages` overlays
modules = final: prev: {
  mmell = (prev.mmell or {}) // {
    modules = (prev.mmell.modules or {}) // {
      retrom = retrom.nixosModules.retrom;
    };
  };
};
```

The guest then imports it from `pkgs`:

```nix
{config, pkgs, ...}: {
  imports = [pkgs.mmell.modules.retrom];
  # …
}
```

Why overlay rather than `commonModules`: putting the module in the
common list would load Retrom's option schema on every NixOS host
in the flake (router, NAS, all VMs), pulling in the upstream module
even where it isn't wanted. The overlay keeps it scoped to the one
guest that imports it.

### `modules/retrom.nix` on oracion

```nix
{config, pkgs, ...}: let
  vhost = "retrom.internal";
in {
  imports = [pkgs.mmell.modules.retrom];

  services.retrom = {
    enable = true;
    enableDatabase = true;        # local Postgres, peer auth
    port = 5101;
    settings = {
      content_directories = [
        # Windows games: each title = a directory of installer/binary files.
        { path = "/media/library/games/windows";
          storage_type = 1;  # MULTI_FILE_GAME
        }
        # Linux games: same shape (each title a directory).
        { path = "/media/library/games/linux";
          storage_type = 1;  # MULTI_FILE_GAME
        }
        # Console ROMs: each first-level subdir is a platform, each
        # ROM is a single file (Igir default {dir-game-subdir multiple}
        # only nests multi-file titles, but using SINGLE_FILE_GAME here
        # would force every ROM flat per platform). Use CUSTOM with the
        # explicit macro so Retrom expects mixed single+multi at the
        # game level, matching what Igir produces with default settings.
        { path = "/media/library/games/consoles";
          storage_type = 2;  # CUSTOM
          custom_library_definition = {
            definition = "{library}/{platform}/{gameDir}";
          };
        }
      ];
      # mister/ is a sibling, not nested under any scanned path,
      # so no ignore_patterns entry needed.
    };
  };

  # Pin Postgres to match upstream Retrom's embedded build (PG 17),
  # so a future move to embedded mode (see §7) doesn't migrate
  # versions. Locks our nixpkgs-Postgres at a known rev.
  services.postgresql.package = pkgs.postgresql_17;

  security.acme.certs."${vhost}".group = "acme-cert";

  services.nginx.virtualHosts."${vhost}" = {
    forceSSL = true;
    enableACME = true;
    # HTTP/2 on the listen socket so tonic gRPC (used by the desktop
    # client) terminates here cleanly. nginx's default `listen 443
    # ssl;` is HTTP/1.1 only, which breaks gRPC at the proxy.
    http2 = true;
    locations."/" = {
      # Web client (REST + gRPC-Web) over HTTP/1.1 — fine via
      # proxy_pass.
      proxyPass = "http://127.0.0.1:5101";
      extraConfig = ''
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
    # Desktop client speaks raw tonic gRPC (HTTP/2). Route the
    # gRPC content type with grpc_pass for HTTP/2 end-to-end.
    # Retrom multiplexes REST + gRPC + WebDAV on one port, so
    # this differentiates by Content-Type.
    locations."= /grpc" = {
      extraConfig = ''
        if ($content_type ~* "application/grpc") {
          grpc_pass grpc://127.0.0.1:5101;
        }
      '';
    };
  };

  environment.persistence."/persist".directories = [
    { directory = "/var/lib/retrom"; user = "retrom"; group = "retrom"; }
    { directory = "/var/lib/postgresql"; user = "postgres"; group = "postgres"; }
  ];
}
```

**nginx + gRPC caveat.** Retrom's service crate depends on
`retrom-grpc-service` (tonic, HTTP/2-only), `retrom-rest-service`
(HTTP/1.1), and `retrom-webdav-service` — all multiplexed on one
port via tower routing. Plain `proxy_pass http://...` works for
the web client (gRPC-Web wire format over HTTP/1.1), but the
desktop client likely uses raw tonic gRPC over HTTP/2 and will
need `grpc_pass`. Upstream documentation doesn't cover reverse
proxying, so the exact split between gRPC-Web and raw gRPC needs
deploy-time validation. Fallback if the nginx-multiplexed setup
proves fragile: open `5101/tcp` directly on the trusted VLAN for
the desktop client, keep nginx for the web client only.

**Schema notes** (verified against
`packages/codegen/protos/retrom/server/config.proto` upstream):

- `ServerConfig.content_directories` is a list — multiple roots
  are first-class (one per `path`).
- `ContentDirectory` fields: `path` (string), `storage_type`
  (optional `StorageType`), `ignore_patterns` (optional), and
  `custom_library_definition` (optional, just a
  `{ definition = "<macro string>"; }` wrapper).
- `StorageType` enum: `SINGLE_FILE_GAME = 0`,
  `MULTI_FILE_GAME = 1`, `CUSTOM = 2`. Numeric values used because
  the upstream NixOS module passes `settings` straight to a JSON
  config file, and the codegen serializer encodes enum variants as
  integers.
- Macros for `CUSTOM`: `{library}`, `{platform}`, `{gameDir}`,
  `{gameFile}`. `{gameDir}` and `{gameFile}` are mutually exclusive
  in a single definition. Custom macros (e.g. `{region}`) are
  permitted for tagging but not required here.
- Connection fields (`dbUrl`, `port`) are populated by the upstream
  module from `cfg.port` and `enableDatabase`; do not override.

**Postgres footprint.** Oracion didn't previously run Postgres.
This is a new service surface on the guest. Persist
`/var/lib/postgresql` (the version subdir will appear on first
boot — adjust the persist entry to match the deployed Nix's default
Postgres version).

**Read access.** Retrom runs as the `retrom` system user. NFS files
arrive squashed to `media:media` (uid/gid 400) mode 0664;
world-readable bit covers Retrom's read.

### Library scan configuration

Library scan content roots are declared in the Nix `settings.content_directories`
(see module above) — Retrom does not require post-deploy UI steps for content
roots, only for admin signup + initial scan trigger.

| Content directory               | storage_type / definition                    | Platform model                                                                |
| ------------------------------- | -------------------------------------------- | ----------------------------------------------------------------------------- |
| `/media/library/games/windows`  | `MULTI_FILE_GAME`                            | One implicit platform (the directory itself)                                  |
| `/media/library/games/linux`    | `MULTI_FILE_GAME`                            | One implicit platform                                                         |
| `/media/library/games/consoles` | `CUSTOM` w/ `{library}/{platform}/{gameDir}` | First-level subdir = platform (DAT name, e.g. `Nintendo - Game Boy Advance/`) |
| `/media/library/games/mister`   | _not declared_                               | Derived hardlink view, intentionally unscanned                                |

The console platform names come from Igir's `--dir-dat-name` output —
the DAT's own name becomes the directory and Retrom surfaces it as the
platform label. Once Igir has populated the tree, trigger a rescan.

### Service-named vhost — `lib/common/data/network.nix`

Add `retrom.internal` to oracion's `hostAliases`:

```nix
oracion = [
  "jellyfin.internal.mutantmell.net"
  "jellyfin.internal"
  "navidrome.internal.mutantmell.net"
  "navidrome.internal"
  "retrom.internal.mutantmell.net"   # NEW
  "retrom.internal"                   # NEW
];
```

Phantasma's `dns.nix` picks this up via `mkUnboundAliasData`. After
phantasma deploys, `getent hosts retrom.internal` resolves to
oracion's IP from anywhere on the internal network.

### Egress — no change needed

oracion's existing allowlist already includes `tcp/{80,443}` to any
host (covers IGDB, SteamGridDB, Retrom update checks) and
basel:443 (ACME). No new egress rules.

### Firewall (input chain)

`networking.firewall.allowedTCPPorts` doesn't need 5101 opened —
nginx is the only listener on the public-facing side; Retrom's
5101 stays bound to 127.0.0.1. Match the Navidrome pattern.

## §4 — Ingestion on bose

Three ingestion paths, all running on bose as `mediaops` so output
ownership is `media:media` 0664/2775 and matches the rest of the
library's shape.

### §4.1 Console ROMs — Igir

Same shape as FileBot / beets / picard: a CLI on bose, runs as
`mediaops`, reads from `/media/manual/games/roms/`, writes to
`/media/library/games/consoles/<platform>/`.

#### Nix change — `hosts/liberl/microvm/guests/bose/modules/arr.nix`

```nix
let
  igir-ingest = pkgs.writeShellApplication {
    name = "igir-ingest";
    runtimeInputs = [pkgs.igir];
    text = ''
      umask 0002
      exec igir "$@"
    '';
  };
in {
  environment.systemPackages = [
    # … existing …
    pkgs.igir
    igir-ingest
  ];
}
```

Same umask wrapper rationale as `filebot-ingest` and `beets-ingest`:
without `umask 0002` Igir inherits operator default 0022 and
produces group-readable-but-not-writable trees, which then break
later re-ingestion / cleanup.

#### DAT files

Igir consumes DAT files (No-Intro, Redump, MAME, FBNeo) for
verification + canonical naming. **No-Intro's datomatic blocks
automated downloads** and igir doesn't ship a built-in fetcher
for No-Intro/Redump — DATs must be operator-fetched (the
datomatic UI requires a captcha-style download flow).

Workflow: operator downloads the relevant `.zip` from datomatic
manually, scps it to bose under `/persist/dats/`, and references
it with `--dat /persist/dats/<file>.zip`. Refresh the local copy
manually when releases warrant it (No-Intro updates infrequently).

`/persist/dats/` is not pre-declared via tmpfiles since it's
operator-curated content; create on first use. Belongs in the
runbook addendum that lands with PR 1.

#### Canonical ROM ingest workflow (operator-facing, runbook §3.6)

Use `--dir-dat-name` so each console gets a directory keyed on the
DAT's own name (`Nintendo - Game Boy Advance/`, etc.). Retrom
surfaces the directory name as the platform label in its UI; the
verbose DAT name is descriptive enough and avoids a manual rename
step. Subsequent runs against the same DAT produce the same
directory name consistently.

```
su - mediaops
igir copy extract test clean \
    --dat    /persist/dats/<source>.zip \
    --input  /media/manual/games/<platform>/ \
    --output /media/library/games \
    --dir-dat-name \
    --dir-game-subdir always \
    --no-bios
```

- `copy extract test clean` — copy in (preserve staging input),
  extract archives, verify against DAT, prune unverified output.
- `--dir-dat-name` — output goes into a per-DAT subdir
  (`games/Nintendo - Game Boy Advance/<game>/...`).
- `--dir-game-subdir always` — every game gets its own subdir,
  matching the `{gameDir}` macro in the Retrom CUSTOM definition
  (mixed single+multi handled uniformly).
- `--no-bios` — skip BIOS files; emulators load those out-of-band.

### §4.2 Windows / native Linux games — manual organization

No DAT, no canonical-rename concept — operator-managed. Workflow:

1. Drop installer / extracted game directory into
   `/media/manual/games/{windows,linux}/<incoming>/`.
2. On bose, as `mediaops`, organize into the library tree:
   ```
   mv /media/manual/games/windows/<incoming>/<MyGame> \
      /media/library/games/windows/<MyGame>/
   ```
   With `MULTI_FILE_GAME` storage type on these roots, Retrom
   treats every direct child of `windows/` (or `linux/`) as one
   game and indexes everything inside that child as the game's
   files. Layout _inside_ `<MyGame>/` is operator-discretion —
   typically an installer, a pre-extracted tree, or both.
3. Retrom picks up new entries on its next library scan.

This stays manual for now. A future plan can wrap GoG / itch
backups (`gogrepoc`, `lgogdownloader`, `butler`) in a similar
`*-ingest` shell wrapper if/when bulk acquisition becomes a real
workflow. Out of scope here.

### §4.3 MISTer view — Igir link mode

Generate the case-sensitive MISTer-shaped tree as **hardlinks**
into the canonical `consoles/` tree. Igir has built-in MISTer
support via the `{mister}` output token (lowercase, confirmed
against igir.io/usage/hardware/mister/), which expands to MISTer's
case-sensitive core dir names (`Gameboy`, `SNES`, `MegaDrive`,
`PSX`, …) keyed off the input DAT name.

#### Workflow

After (or as part of) each ROM ingest, run a second Igir invocation
that walks `library/games/consoles/` and produces hardlinks into
`library/games/mister/games/<Core>/`:

```
igir-ingest link \
    --dat    '<same dat as the ingest run>' \
    --input  /media/library/games/consoles \
    --output '/media/library/games/mister/games/{mister}' \
    --link-mode hardlink \
    --no-bios
```

`link` is a separate igir command (not a flag): it emits hardlinks
(or symlinks/reflinks per `--link-mode`) from `--input` into
`--output`. `--link-mode hardlink` is the default but is named
explicitly here for runbook clarity. The DAT is required so igir
can resolve the `{mister}` token from each game's parent DAT.

#### Why hardlinks, not symlinks or copies

- **Single-dataset hardlinks are free.** ZFS hardlinks within
  `data/media` cost one extra directory entry per link, no extra
  bytes — already foundational to the spec (per
  `plans/media-organization-pipeline.md` §1.5, `data/media` is a
  single dataset _specifically_ to keep hardlinks working).
- **Symlinks are a CIFS liability.** MISTer mounts CIFS shares for
  remote-storage mode; symlink semantics over CIFS are
  client-implementation-dependent and historically fragile.
- **Copies waste space** and create a sync problem: the canonical
  ROM gets re-verified, the MISTer copy doesn't.

#### MISTer arcade (`_Arcade/`) — defer

Arcade ingestion (MRA + ROM zips, MAME / FBNeo DAT mapping) has
its own workflow and naming conventions. Deferred until a real
MISTer arcade workflow is needed. When added, it'll follow the
same pattern: Igir with arcade-mode flags, output to
`library/games/mister/_Arcade/`.

### §4.4 What MISTer mounts (note for runbook, not Nix work)

The MISTer firmware can mount a CIFS share at boot via
`cifs.txt`. To present `library/games/mister/` to the FPGA:

- Liberl's existing Samba `media` share (path `/data/media`,
  trusted-VLAN access) already exposes this tree at
  `library/games/mister/`. The MISTer can bind that path or a
  subset of it into its in-firmware locations (`/media/fat/games/`
  is conventionally on the SD card; the network mount becomes
  `/media/network/...` and is symlinked or `cifs_mount`-overlaid
  per MISTer convention).
- This means MISTer reads game data over **SMB** (trusted-VLAN
  squash semantics, currently RW for the trusted VLAN — see the
  spec's "SMB media share rework" future-goal). Not over NFS —
  MISTer's stock firmware doesn't speak NFS.
- **Trade-off**: this re-uses the existing trusted-VLAN-RW SMB
  share. The spec's least-privilege rework (RW SMB shrunk to a
  dedicated upload share, RO SMB exposed for consumers) would
  shrink MISTer to RO SMB once that work happens. Until then,
  MISTer relies on the same shared-trust model the rest of the
  trusted VLAN uses.

This is a runbook concern, not a Nix change. Document the MISTer
`cifs.txt` template in the runbook addendum that lands with PR 2.

## §5 — Implementation order

The work splits cleanly into two PRs.

### PR 1 — Storage + Igir on bose

1. Add `manual/games`, `library/games`, `mister`, `mister/games`
   tmpfiles entries to `hosts/liberl/nas.nix` per §2.
2. Add `igir` wrapper to bose's `modules/arr.nix` per §4.1.
3. `nix fmt && ./scripts/run-checks.sh`.
4. Deploy liberl + bose. Tmpfiles materialize; `igir` is on
   `mediaops`'s PATH.
5. Smoke tests:
   - `su - mediaops; igir --version`.
   - Drop one small no-intro-verifiable ROM into
     `/data/media/manual/games/<platform>/`, run the §4.1
     `igir copy extract test clean --dir-dat-name
--dir-game-subdir always ...` invocation. Verify the file
     lands at e.g.
     `library/games/Nintendo - Game Boy Advance/<game>/<canonical>.gba`,
     mode 664, owned `media:media`.
   - Run the link pass: `igir link --link-mode hardlink
--dat ... --input /media/library/games
--output '/media/mister/games/{mister}'`.
     Verify the hardlink at e.g.
     `mister/games/GBA/<canonical>.gba` shares an
     inode with the canonical file (`stat -c '%i' <both>` matches).
   - Operator-place one Linux game directory into
     `library/games/<MyGame>/` (manual mv from a staged
     tarball); verify ownership / permissions.

### PR 2 — Retrom on oracion + service-named vhost

1. Add `inputs.retrom = "github:JMBeresford/retrom"` to
   `flake.nix` (with `inputs.nixpkgs.follows`).
2. Add `retrom.cachix.org` substituter + public key to
   `flake.nix` `nixConfig` (skip the long Rust build).
3. Add a `modules` overlay to `flake.nix` that exposes
   `pkgs.mmell.modules.retrom = retrom.nixosModules.retrom`,
   alongside the existing `lib` and `packages` overlays.
4. Add `retrom.internal` aliases to `oracion` in
   `lib/common/data/network.nix` `hostAliases`.
5. New file
   `hosts/calvard/microvm/guests/oracion/modules/retrom.nix`
   per §3 (imports `pkgs.mmell.modules.retrom`, declares three
   `content_directories` in `settings`, pins Postgres 17, enables
   nginx vhost with `http2 = true`, persistence). Add the new
   module to oracion's `default.nix` `imports`.
6. `nix fmt && ./scripts/run-checks.sh`.
7. Deploy phantasma (DNS picks up the new alias), then
   calvard/oracion.
8. Verify DNS: `getent hosts retrom.internal` → oracion.
9. Verify ACME: `systemctl status acme-retrom.internal`.
10. **First-run UI**: browse to `https://retrom.internal/`,
    complete admin signup, trigger initial library scan.
    `content_directories` were declared in Nix and are already
    loaded — no UI configuration of roots needed.
11. Verify desktop client connects from a workstation. If the
    desktop client fails over the nginx vhost (gRPC routing
    issue), fall back to opening `5101/tcp` on the trusted VLAN
    and pointing the client at oracion:5101 directly — keep nginx
    for the web client only.
12. Verify ROM, Windows game, and Linux game all surface as
    separate platforms with no MISTer-tree duplication.

## §6 — Test plan

Operational, no NixOS test harness. Per-PR checks:

### After PR 1 (storage + Igir)

1. On liberl: `ls /data/media/{manual,library}/games/...` exists,
   mode 2775, owned 400:400.
2. From bose: `ls /media/{manual,library}/games/...` resolves; can
   write from `mediaops`, cannot write from `nobody`.
3. Live test — console ROM:
   - `rsync` one no-intro-verifiable ROM (e.g. a small GBA file)
     to `/data/media/manual/games/roms/incoming/`.
   - On bose, run the `igir-ingest copy extract test clean
--dir-dat-name --dir-game-subdir always ...` invocation per
     §4.1.
   - Verify file lands at e.g.
     `/media/library/games/consoles/Nintendo - Game Boy Advance/<game>/<canonical>.gba`,
     mode 664, owned `media:media`.
   - Rename the DAT-named subdir to the homelab short code:
     `mv "consoles/Nintendo - Game Boy Advance" consoles/gba`.
4. Live test — MISTer link pass:
   - On bose, run the `igir-ingest link --link-mode hardlink
--output '.../{mister}' ...` invocation per §4.3.
   - Verify e.g. `library/games/mister/games/Gameboy/<canonical>.gb`
     (or the appropriate core dir; `{mister}` produces names like
     `Gameboy`, `GBA`, `SNES`, `MegaDrive`, `PSX`).
   - `stat -c '%i %h' /media/library/games/consoles/gba/<game>/<file>
        /media/library/games/mister/games/GBA/<file>`
     — both should report the same inode and link count ≥2.
   - Negative case: `rm` the canonical file → MISTer hardlink
     still resolves (inode persists until last name unlinked).
     Then re-create canonical via Igir and re-run link pass to
     restore both.
5. Live test — PC game:
   - Stage a tiny tarball under
     `/media/manual/games/linux/<incoming>/<MyGame>/`.
   - `mv` to `library/games/linux/<MyGame>/`.
   - Verify mode 2775, owned `media:media`.

### After PR 2 (Retrom)

1. On oracion: `systemctl status retrom postgresql` healthy.
2. `curl -k https://retrom.internal/` returns the web client.
3. From a workstation, browse to `https://retrom.internal/`,
   admin signup completes, library scan finds the seeded console
   ROM **and** the seeded Linux game **and** any seeded Windows
   game.
4. Verify MISTer tree is **not** indexed by Retrom (no duplicate
   ROM entry under a "MISTer" platform).
5. Install the Retrom desktop client (release binary or
   `homeModules.retrom`), connect to `https://retrom.internal/`,
   confirm games appear in their respective platforms.
6. Cross-verify NFS read path: `ls
/media/library/games/consoles/...` from oracion succeeds RO;
   `touch /media/library/games/.x` fails EROFS.
7. Postgres impermanence: reboot oracion, verify Retrom still has
   the library and admin user (postgres data persisted).

## §7 — Future / non-blocking

- **Bulk migration of existing collections.** Same shape as the
  music bulk migration: rsync batches into `manual/games/...`,
  run Igir for ROMs, manual mv for PC games, let Retrom rescan.
  Document in the runbook once PR 2 lands.
- **Retrom embedded Postgres** (alternative to NixOS-managed
  Postgres). Retrom's `retrom-db` crate has an `embedded` cargo
  feature backed by `postgresql_embedded` — pinned to PG 17.2.0,
  managed by Retrom's own process, persisted under `dataDir`.
  Upstream's `nix/pkgs/retrom-service/package.nix` does **not**
  enable this feature, so adopting it requires either an
  `overrideAttrs` adding `--features embedded_db` to the build
  flags, or a fork of the package. Trade-offs: one fewer service
  on the guest and tighter Retrom/Postgres version coupling, vs.
  losing the standard `pg_dump`/observability path and taking on
  a runtime postgres-binary fetch (postgresql_embedded extracts
  a binary into the data dir on first run — needs verification
  that this works under impermanence + the existing oracion
  egress allowlist). Pinning `services.postgresql.package =
pkgs.postgresql_17` in PR 2 keeps a switch-to-embedded
  realistic without a version migration.
- **MISTer arcade (`_Arcade/`).** Add MRA + arcade-ROM ingest
  workflow when an arcade-on-MISTer use case appears. Same Igir
  pattern; arcade DATs (MAME / FBNeo) have their own quirks.
- **PC game ingestion automation.** GoG / itch.io / Heroic-managed
  libraries are ripe for a `gog-ingest` / `itch-ingest` wrapper
  similar to `filebot-ingest`. Defer until bulk acquisition is a
  real workflow.
- **Steam library bridge (Retrom → desktop Steam).** Retrom can
  unify a client's local Steam install into the same UI; per-client
  setting, no server change.
- **MISTer save / SRAM sync.** A separate writable path (NOT under
  RO library) for per-client save data, network-shared if the user
  wants seamless save sync between MISTer + desktop emulators.
  Out of scope — design separately.
- **Authelia integration.** Retrom has its own user system; defer
  Authelia OIDC integration until the broader Authelia migration
  (`wip/authelia-migration-plan.md`) is far enough along to add a
  new client. Until then, Retrom's built-in auth + TLS is the
  access boundary.
- **EmulatorJS in-browser play (regression from the spec).**
  Retrom doesn't ship browser emulation. If ever needed (share with
  friends without a client install), add a separate EmulatorJS
  instance later — same RO NFS read pattern, separate vhost.
- **`library-hq/games/` tier.** Skipped (single canonical artifact
  per title). Revisit only if a real driver appears (e.g.,
  collector-edition installers that need to coexist with the
  primary release).
- **MISTer SMB → RO via the spec's SMB-rework.** When the
  least-privilege SMB rework lands, MISTer's CIFS mount should be
  pointed at the RO SMB share. Cross-reference here so the
  rework's PR remembers to validate MISTer.
