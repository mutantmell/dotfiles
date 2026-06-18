# liberl Backups Hierarchy and Forgejo Repository Backup Plan

> **Status:** Planning.
>
> This plan creates a ZFS-backed backup namespace on liberl, migrates the old
> Windows-oriented `/data/backup` usage into that namespace, and adds a
> service-level backup path for Forgejo repositories hosted on `creil`.

## Goal

Make liberl the durable backup aggregation point for homelab service and host
state, starting with Forgejo repositories.

The target storage shape is:

```text
data/backups
data/backups/workstations
data/backups/host
data/backups/service
data/backups/service/forgejo
```

Mounted paths:

```text
/data/backups/workstations
/data/backups/host
/data/backups/service
/data/backups/service/forgejo
```

The old singular `/data/backup` path should become legacy-only data to triage,
not the active backup root.

## Current State

- liberl imports the ZFS `data` pool and runs ZFS scrub/trim.
- `hosts/liberl/nas.nix` currently exposes a Samba share named `backup` at
  `/data/backup`.
- There is no declarative ZFS dataset hierarchy for backups yet.
- Forgejo runs on `creil`, a microVM on calvard.
- Forgejo persists `/var/lib/forgejo` inside the creil local persist image:
  `/persist/guests/creil/images/persist.img` on calvard.
- Forgejo uses SQLite and has repository/package/mirror support enabled.
- `llm-notes/plans/cicd-fleet-activation-plan.md` already says creil should be
  the primary git remote and GitHub should become a push mirror for the
  dotfiles repo, but that is not a liberl/ZFS backup.
- `llm-notes/done/wg-ba-liberl-backup-tunnel-plan.md` establishes liberl as the
  host with an offsite SSH/Borg path, but no local Forgejo-to-liberl backup
  source exists yet.

## Design

### Backup hierarchy

Use `data/backups` as the policy root.

Recommended dataset roles:

| Dataset | Purpose |
| --- | --- |
| `data/backups` | Backup-wide defaults and inheritance root |
| `data/backups/workstations` | Windows/client workstation backups exposed by Samba |
| `data/backups/host` | Host-level backups such as VM images, `/persist` copies, or host-specific state |
| `data/backups/service` | Service-level backups independent of current host placement |
| `data/backups/service/forgejo` | Forgejo repository mirrors and Forgejo metadata dumps |

Keep service backups and host backups separate because they restore at different
boundaries. Forgejo repositories are service data, not calvard host data. A
future image-level backup of creil's persist disk can live under
`data/backups/host/calvard` or a more specific host/guest path, but it should
not be the only Forgejo backup.

### Legacy `/data/backup`

Preserve `/data/backup` as legacy data until manually triaged.

Do not point active Samba or service backup jobs at `/data/backup` after the
migration. If `/data/backup` is already a separate ZFS dataset, keep it mounted
as-is and rename it later only after checking its contents. If it is just a
directory under the pool root, leave it in place as `/data/backup` and treat it
as read-only legacy data by convention until the operator moves or deletes it.

### Samba exposure

Move the Samba `backup` share from:

```text
/data/backup
```

to:

```text
/data/backups/workstations
```

Do not expose `/data/backups`, `/data/backups/service`, or
`/data/backups/host` through the existing broad workstation share. Service and
host backups should be machine-owned and not writable by desktop clients.

### Forgejo repository backups

Use a liberl-owned pull backup, not a live NFS mount into creil.

Reasons:

- The live Forgejo service should not depend on liberl being online.
- Git repository storage over NFS adds avoidable correctness and performance
  risk.
- liberl is the durable storage target; it can pull into ZFS and snapshot its
  own local filesystem.
- A pull job centralizes backup policy on the NAS instead of depending on
  per-repository push mirror settings in Forgejo.

Target path:

```text
/data/backups/service/forgejo/git-mirrors
/data/backups/service/forgejo/dumps
```

The git mirror job should:

- run on liberl as a dedicated `forgejo-backup` system user;
- use a read-only Forgejo credential stored through sops-nix;
- enumerate repositories through the Forgejo API, or start with an explicit
  allowlist if broad API scope is not acceptable;
- maintain local bare mirrors with `git clone --mirror` and
  `git remote update --prune`;
- fetch Git LFS objects for repositories that use LFS;
- write under `/data/backups/service/forgejo/git-mirrors/<owner>/<repo>.git`;
- avoid deleting mirror directories automatically unless the deletion policy is
  explicit and ZFS snapshots are already in place.

The mirror job must also validate inventory coverage. A backup credential that
cannot see every private user repository, organization repository, wiki
repository, or future namespace silently creates a false sense of safety. The
first implementation should compare the expected repository/wiki inventory with
the mirrored path set and fail loudly on missing entries. If the API token's
scope cannot make that reliable, use an explicit repo allowlist until Forgejo
permissions are corrected. Include `git-lfs` in the job environment and verify
that LFS-backed repositories fetch their LFS object set, not only git refs.

The metadata dump job should:

- capture Forgejo application state that plain git mirrors do not restore:
  users, orgs, issues, pull requests, hooks, repo settings, packages/registry
  metadata if desired, and SQLite state;
- run less frequently than git mirror updates unless the service grows enough
  to justify tighter RPO;
- store timestamped archives under `/data/backups/service/forgejo/dumps`;
- document restore expectations separately after the first successful dump.

The initial Forgejo backup should prioritize repositories. Full Forgejo
application restore can be a second phase.

### Snapshot and retention policy

Create snapshots at the dataset boundary rather than relying only on git mirror
history.

Suggested starting policy:

| Dataset | Snapshot cadence | Retention |
| --- | --- | --- |
| `data/backups` | none directly, inheritance root only | n/a |
| `data/backups/workstations` | daily | 30 daily, 12 monthly |
| `data/backups/host` | daily or per-job | 14 daily, 8 weekly, 6 monthly |
| `data/backups/service` | none directly, children own policy | n/a |
| `data/backups/service/forgejo` | hourly and daily | 48 hourly, 30 daily, 12 monthly |

The exact implementation can be either:

- a simple local systemd timer wrapping `zfs snapshot` and pruning by naming
  convention; or
- a maintained ZFS snapshot manager from nixpkgs, if the active nixpkgs has a
  suitable NixOS module.

Prefer the maintained module if it fits cleanly. If not, keep the first version
small and local: named recursive snapshots plus age/count pruning for
`data/backups/service/forgejo`.

### Offsite path

The existing liberl `wg-ba` path is already designed for SSH/Borg to a remote
backup host. Once local `data/backups` datasets are populated and snapshotted,
add a follow-up phase to send selected datasets offsite.

Initial offsite priority:

1. `data/backups/service/forgejo`
2. critical host backups under `data/backups/host`
3. workstation backups if capacity and upload budget allow

## Phases

### Phase 1 - ZFS backup hierarchy

Operator one-time steps on liberl:

```bash
zfs create -o mountpoint=/data/backups data/backups
zfs create data/backups/workstations
zfs create data/backups/host
zfs create data/backups/service
zfs create data/backups/service/forgejo
```

Apply baseline properties after confirming the pool's current conventions:

```bash
zfs set compression=zstd data/backups
zfs set atime=off data/backups
```

Consider `recordsize=16K` only for git-heavy datasets after measuring or
checking current pool defaults. Do not blindly set aggressive properties on the
whole backup tree.

Nix changes:

- Add tmpfiles rules for the mounted backup directories.
- Create a `forgejo-backup` system user/group with no login shell.
- Ensure `/data/backups/service/forgejo` is owned by `forgejo-backup`.
- Keep `/data/backups/workstations` owned according to the Samba workstation
  backup access model.
- Backup services that write under these paths must include
  `RequiresMountsFor=/data/backups/service/forgejo` and should use
  `ConditionPathIsMountPoint=/data/backups/service/forgejo` or an explicit
  `findmnt` preflight. They must fail closed if the ZFS dataset is not mounted,
  rather than creating backup data on the parent filesystem.

### Phase 2 - Move workstation Samba share

Nix changes in `hosts/liberl/nas.nix`:

- Change Samba share `backup.path` from `/data/backup` to
  `/data/backups/workstations`.
- Update comments so `/data/backup` is clearly legacy.
- Do not expose `/data/backups` itself.

Operator validation:

```bash
smbclient -L //liberl.internal -U mutantmell
smbclient //liberl.internal/backup -U mutantmell -c 'ls'
```

Confirm the share lands in `/data/backups/workstations`, not `/data/backup`.

### Phase 3 - Local ZFS snapshots

Add a snapshot policy for at least:

```text
data/backups/service/forgejo
data/backups/workstations
```

Validation:

```bash
findmnt /data/backups/service/forgejo
zfs snapshot data/backups/service/forgejo@manual-test
zfs list -t snapshot -r data/backups/service/forgejo
zfs destroy data/backups/service/forgejo@manual-test
```

If using an automated snapshot service, validate one scheduled run before
relying on it.

### Phase 4 - Forgejo git mirror backup

Nix changes:

- Add `hosts/liberl/forgejo-backup.nix` and import it from
  `hosts/liberl/default.nix`.
- Add sops secret(s) for the Forgejo backup credential.
- Add a systemd service and timer for repository mirror updates.
- Add egress assumptions explicitly. liberl currently does not use a strict
  whole-host egress allowlist, but future liberl firewall tightening should
  allow liberl to reach `creil` on TCP 22 and/or 443 for this job.

Credential options:

| Option | Pros | Cons |
| --- | --- | --- |
| Forgejo API token + HTTPS clone token | Easy repo enumeration | Token scope must be reviewed carefully |
| Dedicated SSH key attached to a read-only Forgejo user | Good git transport fit | API enumeration still needs token or explicit repo list |
| Explicit repo allowlist with SSH URLs | Least API surface | Manual upkeep when repos are added |

Recommended first implementation: dedicated `forgejo-backup` Forgejo user with
read-only access plus a sops-managed token for API enumeration. If that scope is
too broad, fall back to an explicit repo list for the initial rollout.

Validation:

```bash
findmnt /data/backups/service/forgejo
systemctl start forgejo-git-mirror-backup.service
systemctl status forgejo-git-mirror-backup.service
find /data/backups/service/forgejo/git-mirrors -maxdepth 3 -name '*.git' -type d
git --git-dir=/data/backups/service/forgejo/git-mirrors/<owner>/<repo>.git fsck
```

### Phase 5 - Forgejo metadata dumps

Add a lower-frequency job that captures Forgejo application metadata and SQLite
state.

Open implementation decision:

- run and stage the dump command on creil, then have liberl pull the archive
  over SSH from `creil:22` with a restricted key; or
- trigger the dump from liberl over SSH to creil, then pull the generated
  archive back over the same connection.

Prefer running Forgejo-native dump logic on creil, because it knows the active
Forgejo paths and can quiesce or coordinate with the local service. Prefer a
liberl-pull transfer direction: creil already exposes SSH, while liberl's host
firewall is intentionally narrow and should not grow a creil-to-liberl SSH
exception just for backup uploads. After a successful pull, remove the staged
archive from creil. Store only the resulting archive under
`/data/backups/service/forgejo/dumps`.

Validation:

- produce one dump archive;
- inspect archive contents for expected repository metadata and database files;
- document a minimal restore drill in `docs/` or `llm-notes/guides/` after the
  first successful test restore.

### Phase 6 - Offsite replication

After local backups and snapshots are stable, add offsite backup coverage for
`data/backups/service/forgejo` using the existing liberl backup tunnel direction.

This phase should be separate from the initial local backup work so local
repository durability is not blocked on offsite retention choices.

## Validation Commands

Use narrow validation first:

```bash
nix build .#nixosConfigurations.liberl.config.system.build.toplevel
```

If touching shared modules or snapshot helpers, run:

```bash
./scripts/agent-preflight.sh --quick
```

After deployment, validate on liberl:

```bash
zfs list -r data/backups
zfs list -t snapshot -r data/backups
test -d /data/backups/workstations
test -d /data/backups/service/forgejo
systemctl list-timers '*forgejo*' '*backup*'
```

## Open Questions

- Should `data/backups` use ZFS encryption, or is pool-level physical security
  enough for now?
- Should old `/data/backup` be renamed as a ZFS dataset, copied into
  `data/backups/workstations/legacy`, or left mounted until manually triaged?
- Should Forgejo package/OCI registry blobs be backed up in the first pass, or
  are git repositories and metadata dumps enough?
- What snapshot manager, if any, should become the repo-wide standard for ZFS
  datasets on liberl?
- Should the first git mirror job use API enumeration or an explicit repo list?
