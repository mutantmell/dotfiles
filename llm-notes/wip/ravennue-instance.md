# Plan: split arr stack across bose (UHD/4K) and ravennue (SD/1080p)

> **Status:** Implemented. ravennue is live and serving SD/1080p arrs.
> The pre-rename tool was subsequently switched from `mnamer` to
> `FileBot` and dropped from ravennue's `arr.nix` (it lives on bose
> only — both guests see the same `/data/media` tree, so single-host
> ingest is sufficient). References to `mnamer` below are historical.

## Goal

Stand up a second arr microVM on liberl — `ravennue` — and split the
arr stack into two instances by quality tier:

- **bose** — retrofit to handle UHD/4K only. Root folders move to
  `/media/library/{movies-4k,tv-4k}`. Bazarr stays here.
- **ravennue** — new microVM, handles SD / 1080p / "everything that
  isn't 4K". Root folders `/media/library/{movies,tv}` (the existing
  unsuffixed paths). Runs its own Bazarr instance scoped to ravennue's
  arrs (Bazarr supports exactly one Sonarr and one Radarr connection
  per instance — see §7).

Reason: Radarr and Sonarr both track exactly **one MovieFile per
Movie / one EpisodeFile per Episode** in their database. Keeping a 4K
and a 1080p version of the same title under the same arr instance
leaves the second copy orphaned in the DB. The community-standard fix
is dual instance with separate root folders. Doing it now is much
cheaper than splitting a populated library later.

End state:

```
liberl
├── /data/media/manual/movies/                  # SD/1080p staging (existing)
├── /data/media/manual/tv/                      #
├── /data/media/manual/music/                   #
├── /data/media/manual/movies-4k/               # UHD/4K staging (new)
├── /data/media/manual/tv-4k/                   #
├── /data/media/library/movies/                 # SD/1080p library (existing)
├── /data/media/library/tv/                     #
├── /data/media/library/music/                  #
├── /data/media/library/movies-4k/              # UHD/4K library (new)
└── /data/media/library/tv-4k/                  #

bose       (10.97.21.43, VLAN 21) — sonarr+radarr+bazarr
                                    UHD/4K library: /media/library/{tv-4k,movies-4k}
ravennue   (10.97.21.44, VLAN 21) — sonarr+radarr+bazarr
                                    SD/1080p library: /media/library/{tv,movies}
```

Note on terminology: "SD" follows the user's wording for ravennue's
tier, but the practical split is **non-4K**: anything below 2160p
(SD, 720p, 1080p) goes to ravennue; 2160p / UHD / 4K goes to bose.

## Why a separate microVM (vs parallel systemd units on bose)

Discussed in the session that produced this plan. Rejected the
parallel-unit-on-bose approach because it requires writing a custom
systemd unit definition (~40-60 lines of Nix per arr) since NixOS has
no `services.radarr-4k` switch. The microVM approach uses **vanilla**
`services.sonarr` and `services.radarr` — the namespace separation is
the VM boundary, not a config-suffix everywhere.

Trade-off accepted: ~8 GB of RAM and 2 vCPUs reserved for the second
guest. Liberl has the headroom; this is what microVMs are for.

## Why bose = 4K and ravennue = SD (vs the reverse)

Either direction works. Picking bose for 4K because:

- bose currently has Bazarr wired up. Keeping bose's Bazarr config
  intact (now scoped to its own arrs) avoids re-doing its provider
  config; ravennue gets its own fresh Bazarr.
- The 4K library will be much smaller than the SD library by item
  count (UHD physical media is rarer). Putting the larger workload on
  the new, fresh instance is fine; putting the smaller workload on
  the existing instance with a config history is also fine. Coin
  flip; this side keeps Bazarr collocated with its first-configured
  arrs, which is mildly nicer.

## What stays the same

- bose's existing identity: hostname, IP, MAC, microvm.cid, persist
  volume, sops creation rules, SSH host key. Only its arr **root
  folder configuration** changes (UI step, not Nix).
- bose's Bazarr config is unchanged — it stays pointed at bose's
  own arrs. ravennue runs a separate Bazarr instance for its arrs
  (Bazarr is single-arr-pair per instance).
- Egress filter shape on the new guest mirrors bose's allowlist.
- Virtiofs share of `/data/media` — both guests see the same tree at
  `/media`.
- mnamer pre-rename step in the runbook — same tool, just split
  staging zones.
- The §4 workflow shape (Library Import → Mass Edit Rename) — uniform
  across both instances.

## What's new

### 1. Network registry — `lib/common/data/network.nix`

Add to the `lab` zone's `hosts` map:

```nix
lab = {
  vlanId = 21;
  hosts = {
    edith = 42;
    bose = 43;
    ravennue = 44;   # SD/1080p arr stack — Sonarr, Radarr (liberl)
  };
};
```

That gives ravennue `10.97.21.44` and the corresponding ULA address.

### 2. New microVM guest — `hosts/liberl/microvm/guests/ravennue/`

Three files, all near-clones of bose's:

#### `default.nix`

Same shape as `bose/default.nix`:

```nix
{
  pkgs,
  config,
  ...
}: let
  hostname = "ravennue";
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost hostname) host zone;
in {
  nix.settings.experimental-features = ["nix-command" "flakes"];
  imports = [
    ./microvm.nix
    ./modules/arr.nix
  ];

  networking.hostName = hostname;
  networking.useNetworkd = true;
  networking.useDHCP = false;
  common.openssh = {
    enable = true;
    keys = ["deploy" "edith"];
  };
  services.openssh.hostKeys = [
    { path = "/static/etc/ssh/ssh_host_ed25519_key"; type = "ed25519"; }
  ];

  systemd.network.enable = true;
  systemd.network.networks."20-tap" = {
    matchConfig.Type = "ether";
    # VLAN 21 = 0x15, host ID 44 = 0x2C
    matchConfig.MACAddress = "5E:15:00:2C:00:01";
    networkConfig = {
      Address = [host.cidr4 host.cidr6];
      Gateway = zone.gateway4;
      DNS = [zone.gateway4 zone.gateway6];
      IPv6AcceptRA = true;
      IPv6PrivacyExtensions = "yes";
      DHCP = "no";
    };
    routes = [
      {Gateway = zone.gateway4;}
      {Gateway = zone.gateway6;}
    ];
  };

  networking.extraHosts = net.mkExtraHosts ["tharbad" "oracion"];

  time.timeZone = "UTC";

  # Sonarr (8989), Radarr (7878), Bazarr (6767)
  networking.firewall.allowedTCPPorts = [8989 7878 6767];

  environment.persistence."/persist" = {
    hideMounts = true;
    directories = [
      "/var/log"
      "/var/lib/nixos"
      "/var/lib/systemd/coredump"
    ];
  };

  zramSwap = {
    enable = true;
    memoryPercent = 50;
  };

  networking.nftables.enable = true;
  networking.nftables.tables.egress = pkgs.mmell.lib.nftables.mkEgressFilter (
    net.mkEgressRules zone [
      # Same allowlist as bose: DNS, NTP, HTTP/HTTPS for metadata,
      # basel:443 (cert enrollment), tharbad:3100 (Loki),
      # tharbad:8427 (metrics), oracion:8096 (Jellyfin Connect).
    ]
  );

  fluent-bit-agent.enable = true;
  node-exporter-client.enable = true;

  system.stateVersion = "25.11";
}
```

Differences from bose:

- `hostname = "ravennue"`.
- MAC: VLAN-21 + host-44 → `5E:15:00:2C:00:01` (0x2C = 44).

#### `microvm.nix`

Same shape as `bose/microvm.nix`:

- `microvm.vsock.cid = 6` (bose uses 5; pick the next free CID).
- `microvm.shares` — same three (`/nix/store`,
  `/persist/guests/ravennue/static`, `/data/media`).
- `microvm.volumes` — `/persist/guests/ravennue/images/persist.img`,
  10 GB.
- `microvm.mem = 8192`, `microvm.vcpu = 2`.
- `microvm.interfaces[0]`: `id = "vm-21-ravennue"`,
  `mac = "5E:15:00:2C:00:01"`.

#### `modules/arr.nix`

Near-identical copy of bose's `modules/arr.nix`:

- Defines `users.users.media` / `users.groups.media` (same as bose).
- `services.sonarr`, `services.radarr`, and `services.bazarr` — same
  flags, same `group = "media"`, same Nice/IO/CPU deprioritization on
  the arrs. Bazarr scoped to ravennue's own arrs only (Bazarr is
  single-arr-pair per instance).
- `environment.systemPackages = [pkgs.mnamer pkgs.mediainfo pkgs.ffmpeg-headless]`
  — same as bose's updated arr.nix (see §6.1). mnamer for the
  pre-rename step, mediainfo / ffprobe for the "is this 4K?"
  staging-time decision (`mediainfo <file> | grep Width`, ≥3840 = 4K).

### 3. Library and staging directory tmpfiles — `hosts/liberl/nas.nix`

Add four entries to `systemd.tmpfiles.rules`:

```nix
(dir "/data/media/library/movies-4k")
(dir "/data/media/library/tv-4k")
(dir "/data/media/manual/movies-4k")
(dir "/data/media/manual/tv-4k")
```

Same `2775 media:media` as the existing entries. The unsuffixed
`movies` / `tv` paths already exist for ravennue's use; new
`-4k`-suffixed paths are for bose's retrofit.

No music-4k. Music ingestion is uncovered until Lidarr is deployed.

### 4. sops creation rule — `.sops.yaml`

Add an age key alias and a creation rule, mirroring bose's:

```yaml
keys:
  - &sv_ravennue <run setup-guest.sh to generate, paste public key here>
...
creation_rules:
  - path_regex: hosts/liberl/microvm/guests/ravennue/secrets/[^/]+\.yaml$
    key_groups:
      - age:
          - *ad_denai
          - *sv_ravennue
```

ravennue has no secrets today (mirroring bose), but the rule is
needed for any future addition (e.g., metric scrape tokens).

### 5. mkExtraHosts — places that need to resolve `ravennue`

The network registry's `hostsFile` covers global resolution; no
manual mkExtraHosts edits should be needed. Confirm by grepping for
`bose` in extraHosts callsites — bose itself only includes `tharbad`
and `oracion`; nothing else lists bose. ravennue inherits the same
shape.

### 6. Bose retrofit

#### 6.1 Nix changes — `bose/modules/arr.nix`

Add to `environment.systemPackages`:

```nix
environment.systemPackages = [
  pkgs.mnamer
  pkgs.mediainfo      # for the staging-time "is this 4K?" check
  pkgs.ffmpeg-headless # ffprobe for the same check
];
```

That's the only Nix change to bose. ravennue's arr.nix is structured
to match (§2).

#### 6.2 Wipe-and-redo (after Nix changes are deployed)

Confirmed acceptable to reset bose's arr DBs from scratch rather than
Mass-Editor-migrate existing entries. Procedure:

1. On liberl: `systemctl stop microvm@bose`.
2. On liberl: `rm /persist/guests/bose/images/persist.img`. This is
   bose's full persist volume — Sonarr/Radarr/Bazarr DBs, configs,
   API keys, settings. The SSH host key under
   `/persist/guests/bose/static/` is **not** in this image and is
   preserved.
3. On liberl: `systemctl start microvm@bose`. The microvm.autoCreate
   flag re-creates an empty 10 GB volume, services start with
   first-run state.
4. Redo bose's first-run UI config (§1.2 / §1.3 / §1.5 / §1.6 of the
   runbook) with the **new** root folders:
   `/media/library/tv-4k` for Sonarr, `/media/library/movies-4k`
   for Radarr.

`/data/media/library/{movies,tv}` is empty (confirmed) — nothing to
relocate during the retrofit. All un-ingested content lives in
`/data/media/manual/` and gets tier-sorted in the pre-sort step
(§6.3).

#### 6.3 One-time tier-sort of existing `manual/` contents

Before running mnamer for the first time under the new workflow,
sort whatever's currently in `/data/media/manual/{movies,tv}/` into
the right tier subdirectory:

```bash
ssh root@liberl

# For each file, decide 4K vs not. Filename hint first; mediainfo
# only when ambiguous (run from bose since that's where mediainfo
# lives, against /media/...).

# Quick filename pass (anything with 2160p / UHD / 4K in the name):
find /data/media/manual/movies -maxdepth 1 -type f \
  \( -iname '*2160p*' -o -iname '*UHD*' -o -iname '*4K*' \) \
  -exec mv {} /data/media/manual/movies-4k/ \;

# Same for TV (recursive, since tv/ may have season subdirs):
find /data/media/manual/tv -mindepth 1 -type d \
  \( -iname '*2160p*' -o -iname '*UHD*' -o -iname '*4K*' \) \
  -exec mv {} /data/media/manual/tv-4k/ \;

# For files without obvious filename markers, spot-check from bose:
ssh root@bose.internal -- 'mediainfo /media/manual/movies/somefile.mkv | grep -E "Width|Height"'
# Width >= 3840 (or Height >= 2160) → 4K → move to manual/movies-4k/

# After sorting, fix permissions on the new -4k dirs (rsync/SMB
# uploads may have arrived with wrong owner).
chown -R 400:400 /data/media/manual/movies-4k /data/media/manual/tv-4k
find /data/media/manual/movies-4k /data/media/manual/tv-4k -type d -exec chmod 2775 {} +
find /data/media/manual/movies-4k /data/media/manual/tv-4k -type f -exec chmod 664  {} +
```

### 7. Per-instance Bazarr first-run (UI step on each guest)

**Retraction:** an earlier draft of this plan asserted Bazarr supports
multiple Sonarr/Radarr targets via a **+ Add** button. It does not —
Settings → Sonarr and Settings → Radarr each take exactly one
connection. Each Bazarr serves exactly one Sonarr + one Radarr.

Concrete plan: bose's Bazarr stays pointed at bose's arrs; ravennue
gets its own Bazarr (added to `ravennue/modules/arr.nix`, port 6767
opened in `ravennue/default.nix`) pointed at ravennue's arrs. First
run is the same UI flow on each guest, against `localhost:8989` /
`localhost:7878`.

Document in §1.6 of the runbook ("do this on both guests, each
configures its own arr pair").

### 8. Connect to Jellyfin from ravennue

ravennue's Sonarr and Radarr each get the same Jellyfin Connect
config as bose's (§1.5 of the runbook). Jellyfin sees four library
entries:

- Movies — `/media/library/movies` (SD/1080p, ravennue)
- Movies 4K — `/media/library/movies-4k` (UHD, bose)
- TV — `/media/library/tv` (SD/1080p, ravennue)
- TV 4K — `/media/library/tv-4k` (UHD, bose)

Jellyfin's **Add Media Library** step (§5 of the runbook) gets two
extra entries.

### 9. Runbook updates — `llm-notes/guides/media-ingestion-runbook.md`

Most changes are additive: ravennue mirrors bose's shape, with the
quality-tier substitution. Concretely:

- **§1.1 (web UIs)** — add ravennue's URLs:
  `http://ravennue.internal:{8989,7878,6767}` (Bazarr now runs on
  both guests, scoped to that guest's arrs).
- **§1.2 / §1.3 (first-run for sonarr/radarr)** — split into a "do
  this on **bose** with `/media/library/{tv-4k,movies-4k}` as root
  folders" block and a parallel "do this on **ravennue** with
  `/media/library/{tv,movies}`" block. Settings (Use Hardlinks,
  Analyze video files, naming format) are identical between the two.
  Add a **Quality Profile** subsection: bose's profiles include only
  2160p qualities (Bluray-2160p, WEBDL-2160p, WEBRip-2160p, Remux-2160p),
  ravennue's profiles include only ≤1080p qualities (and explicitly
  exclude 2160p variants). This enforces tier separation cleanly when
  download clients eventually ship.
- **§1.5 (Connect)** — same note: do once per instance.
- **§1.6 (Bazarr)** — rewrite as "do Bazarr first-run on each guest
  separately. Each instance configures only its own arr pair against
  `localhost:8989` / `localhost:7878`." Bazarr does not support
  multiple Sonarr/Radarr per instance.
- **§2 (staging)** — split into a "is this 4K?" decision:
  ```
  /data/media/manual/movies/      ← SD / 1080p (ravennue)
  /data/media/manual/movies-4k/   ← 2160p UHD (bose)
  /data/media/manual/tv/          ← SD / 1080p (ravennue)
  /data/media/manual/tv-4k/       ← 2160p UHD (bose)
  ```
  How to decide: filename hint (`2160p`, `UHD`, `4K`), or
  `mediainfo <file> | grep Width` (≥3840 → 4K).
- **§3 (mnamer)** — point `--movie-directory` at
  `/media/library/movies` for the SD batch,
  `/media/library/movies-4k` for the 4K batch. Same shape for
  `--episode-directory`. Default to running mnamer **from bose** —
  the runbook's `ssh root@bose.internal` framing stays as-is.
  ravennue has the same `pkgs.mnamer` available if needed, but
  there's no operational reason to switch hosts mid-batch.
- **§4.1 / §4.2 (Library Import + Mass Edit Rename)** — note: open
  ravennue's UI for the SD batch, bose's UI for the 4K batch. Same
  workflow shape on each.
- **§5 (Jellyfin)** — add the two extra library entries.
- **Reference table at end** — add rows or split the existing
  `library/` row into SD vs 4K paths.

## Implementation order

1. Network registry: add `ravennue = 44` to `lab.hosts` in
   `lib/common/data/network.nix`.
2. tmpfiles: add the four library/staging dirs to
   `hosts/liberl/nas.nix`.
3. New guest dir: `hosts/liberl/microvm/guests/ravennue/{default,microvm}.nix`
   and `modules/arr.nix`.
4. **Bose Nix change**: add `pkgs.mediainfo` and `pkgs.ffmpeg-headless`
   to `bose/modules/arr.nix`'s `environment.systemPackages` (§6.1).
5. `.sops.yaml`: placeholder for `&sv_ravennue` plus the creation
   rule. (Public key filled in step 7.)
6. `nix fmt && ./scripts/run-checks.sh` — confirm flake still
   evaluates and existing checks pass.
7. `./scripts/setup-guest.sh liberl ravennue --target root@liberl`.
   Generates SSH host key, derives age key, writes `secrets/` and
   liberl's `/persist/guests/ravennue/static/`.
8. Take the public age key the script produced and paste it into
   `.sops.yaml` against `&sv_ravennue`.
9. Deploy liberl. The new guest auto-discovers via
   `common.microvm.guestDir`. bose picks up the mediainfo/ffmpeg
   addition on the same deploy.
10. Verify: `systemctl status microvm@ravennue` on liberl,
    `ssh root@ravennue.internal -- 'systemctl status sonarr radarr'`.
11. **One-time tier-sort** of `/data/media/manual/{movies,tv}/`
    contents into `-4k` subdirs per §6.3.
12. **Bose retrofit** — wipe and redo. On liberl:
    `systemctl stop microvm@bose`,
    `rm /persist/guests/bose/images/persist.img`,
    `systemctl start microvm@bose`.
13. Run first-run UI config for **both** instances per the updated
    runbook §1.2 / §1.3:
    - bose: root folders `/media/library/{tv-4k,movies-4k}`,
      quality profiles **2160p-only**.
    - ravennue: root folders `/media/library/{tv,movies}`, quality
      profiles **≤1080p only**.
      Plus §1.5 (Connect → Jellyfin) on each.
14. Bazarr first-run on **each** guest separately (§1.6 of runbook,
    §7 of this plan). Each instance points at its own
    `localhost:8989` / `localhost:7878`.
15. On oracion's Jellyfin UI, add the two extra library entries (§8).
16. Apply the runbook diff (§9 of this plan).

## Test plan

Operational, no NixOS test harness:

1. Pre-deploy: `nix fmt && ./scripts/run-checks.sh` baseline.
   Same after the changes — should still pass.
2. Post-deploy: `ping -c1 ravennue.internal` from liberl works.
3. UIs reachable: `curl -s http://ravennue.internal:7878/` returns
   Radarr's HTML; same for `:8989`.
4. **Live test (SD/1080p movie on ravennue)**:
   - Stage one 1080p test movie:
     `rsync` to `liberl:/data/media/manual/movies/Test.2024.1080p.mkv`.
   - From bose (or ravennue): `mnamer --movie-directory=/media/library/movies
... /media/manual/movies/`. Verify the Title (Year) folder
     lands in `/media/library/movies/`.
   - In **ravennue's** Radarr UI: Library Import → folder
     `/media/library/movies` → Import.
   - Mass Editor → Rename Files. Verify file gains MediaInfo tokens.
   - Verify Connect fired: oracion's Jellyfin Activity log shows the
     new entry under Movies.
5. **Live test (4K movie on bose)**:
   - Same procedure with
     `Test.2024.2160p.mkv` →
     `manual/movies-4k/` → mnamer with
     `--movie-directory=/media/library/movies-4k` → bose's Radarr UI
     → Library Import on `/media/library/movies-4k` → Rename Files.
   - Jellyfin Activity log entry under Movies 4K.
6. **Cross-instance independence**: a file dropped in
   `manual/movies/` should not appear in bose's Radarr UI; a file in
   `manual/movies-4k/` should not appear in ravennue's. (Each
   instance only knows its configured root folders.)
7. **Bazarr coverage**: bose's Bazarr shows only 4K titles in its
   dashboard; ravennue's Bazarr shows only SD/1080p titles. Each
   attempts subtitle downloads for its own scope.

## Future / non-blocking

- **Music (Lidarr)**: dual instance is required — user keeps both
  FLAC and MP3 of the same album. Co-locate by tier on the existing
  pair: bose runs Lidarr-FLAC alongside its 4K arrs, ravennue runs
  Lidarr-MP3 alongside its SD arrs. No new microVMs needed; the
  two-VM topology generalizes cleanly as a "tier" abstraction
  (lossless/UHD = bose, lossy/SD = ravennue). When that work
  happens, both guests' `allowedTCPPorts` pick up 8686 and their
  `arr.nix` persistence lists pick up `/var/lib/lidarr`.
- **Editions** (theatrical vs director's cut) are orthogonal to
  encoding — Radarr handles them via `{edition-{Edition Tags}}` in
  the naming token (already in §1.3 TRaSH format). Doesn't need a
  third instance.
- **Resource ceiling**: if Radarr OOMs during bulk import on either
  guest, bump `microvm.mem` temporarily, same as the existing
  troubleshooting note.
