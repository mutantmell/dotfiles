# PQC sops Migration Plan

Move every sops recipient in this repo from classical X25519 (derived from
ed25519 SSH host keys via `ssh-to-age`) to age's native hybrid post-quantum
recipients (`age1pq1...`, ML-KEM-768 + X25519). Migrate the admin recipient
in lockstep. Per-host cutover is hard — single commit swaps the recipient and
ships the new key file in the same deploy — and rollback is via
`nixos-rebuild --rollback`.

## Background

Today, each host's age recipient is the ed25519 SSH host key run through
`ssh-to-age`, and sops-nix reads the SSH private key at boot via
`age.sshKeyPaths`. This double-uses the SSH identity for both SSH auth and
sops decryption, which was convenient but couples them to the same
quantum-vulnerable primitive.

age v1.3.0 (Dec 2024) added native hybrid post-quantum recipients
(`age1pq1...`) and identities (`AGE-SECRET-KEY-PQ-1...`) backed by HPKE with
ML-KEM-768 and X25519. sops ≥ v3.12 vendors age 1.3.1 and decrypts these
recipients with no plugin. The flake pins `nixos-unstable`, which ships a
current sops; sops-nix `sops-install-secrets` builds against a similarly
current `filippo.io/age`.

**Choice:** native age PQC, not a plugin. The alternatives
(`age-plugin-sntrup761x25519`, etc.) are explicitly experimental — the
upstream README warns the file format is unstable. Native PQC is
upstream-FiloSottile, hybrid by default, and decryptable by stock sops with
no extra binary on PATH.

## Decisions

- **Scheme:** native age hybrid (ML-KEM-768 + X25519). Recipient format
  `age1pq1...`, identity format `AGE-SECRET-KEY-PQ-1...`.
- **No mixed-recipient files.** age v1.3.0 refuses to encrypt a file to
  both classical X25519 and PQ recipients in one operation: a mixed file's
  effective security degrades to the weakest recipient, defeating the
  point of PQ, and age enforces this at the tooling level. The migration
  is sequenced so every file is *fully classical* or *fully PQ* at every
  commit — never mixed. The rollback contract is git, not dual recipients:
  reverting the cutover commit restores ciphertext from the prior commit
  along with the classical anchors in `.sops.yaml`, and the rolled-back
  host generation reads it with its SSH-key path.
- **Admin migration:** the admin generates a PQC identity at the start
  and appends it to the existing `pki/ad_denai.key` passage entry,
  which from that point holds both classical and PQ identities — sops
  parses the entry contents the same way it parses a `keys.txt` file,
  so both are loaded on every invocation through the unchanged
  `SOPS_AGE_KEY_CMD = "passage show pki/ad_denai.key"` set in the
  passage-prelude commit. Both halves stay in the same entry throughout
  the rollout because each per-host commit decrypts files with the
  classical admin and re-encrypts to the PQ admin. The classical
  `&ad_denai` anchor stays in `.sops.yaml`'s `keys:` section as long as
  any unmigrated rule references it; the last host's migration commit
  removes it. After Phase 3 the classical half is extracted to a
  passage archive path (kept for forensic decryption of historic
  ciphertexts in git history, not used routinely) and trimmed out of
  `pki/ad_denai.key`, leaving PQ-only. `SOPS_AGE_KEY_CMD` and
  `home/hosts/edith.nix` are untouched throughout the migration.
- **Per-host cutover style:** hard. One commit per host:
  1. Generates and stages the PQC identity (placed via `--extra-files`
     equivalent or pushed directly).
  2. Flips the host's `&sv_<host>` anchor value in `.sops.yaml` from the
     ssh-to-age recipient to the new `age1pq1...` recipient.
  3. Re-keys that host's secrets (`sops updatekeys`).
  4. Switches the host's `sops.nix` from `age.sshKeyPaths` to `age.keyFile`
     pointing at the new identity file.
  - Rollback path: `nixos-rebuild --rollback` on the host returns to the
    generation that reads the old SSH key. The .sops.yaml commit can be
    reverted; the previous generation's `/run/secrets/*` are already
    decrypted and live until reboot or service restart.
- **Identity file storage** (matches the sops-nix README convention):
  - Bare-metal (impermanence): `/var/lib/sops-nix/key.txt`, mode `0400`,
    owned by `root`. Persisted at `/persist/var/lib/sops-nix/key.txt` and
    bind-mounted into `/var/lib/sops-nix/` by impermanence. sops-nix
    configured with `age.keyFile = "/var/lib/sops-nix/key.txt"` —
    identical to the path used in sops-nix's own README example.
  - microVM / Incus guests: `/static/var/lib/sops-nix/key.txt`, served
    via the parent's `/persist/guests/<guest>/static/` virtiofs share
    (the share's internal layout shadows the host filesystem, so the
    path under `/static/` mirrors the bare-metal path). sops-nix
    configured with `age.keyFile = "/static/var/lib/sops-nix/key.txt"`.
    Guests deviate from the upstream default path because the identity
    must live on the static share, not the guest's own `/var/lib`.
  - OpenWrt: unchanged. Secrets are pushed at deploy time, no on-device
    decryption — only the admin recipient matters.
  - Home-manager (`home/hosts/edith`): the admin identity (classical
    only before this plan, classical + PQ during Phase 1–3, PQ-only
    from Phase 4 onward) lives in passage at `pki/ad_denai.key` and is
    loaded into `sops` at invocation time via `SOPS_AGE_KEY_CMD` (set
    once in `home/hosts/edith.nix` as a passage-prelude before this
    plan starts, and not touched again by the migration). No admin
    identity file at rest on the workstation.
  - Ordering caveat: `sops-install-secrets.service` must run after
    impermanence has bind-mounted `/var/lib/sops-nix` on bare-metal (and
    after the virtiofs `/static` mount on guests). The existing
    `/etc/ssh/...` SSH key path has the same dependency and works today;
    calvard's current `sops.nix` points directly at `/persist/etc/ssh/...`
    to sidestep this ordering, but the bind-mounted path is preferable
    and ordering is already correct via sops-nix's default unit
    dependencies — verify on the first cutover host.
- **Anchor naming:** during migration, classical and PQ recipients
  coexist as separate anchors: `&sv_<host>` (classical) and
  `&sv_<host>_pqc` (PQ); `&ad_denai` (classical) and `&ad_denai_pqc` (PQ).
  Each `creation_rule` references one pair or the other — never mixed.
  Per-host migration is a single commit that flips that rule's anchor
  references and removes the now-unreferenced classical `&sv_<host>`
  anchor. After Phase 3, an optional cleanup commit drops the `_pqc`
  suffix from the remaining anchors so the names are back to plain
  `&sv_<host>` / `&ad_denai`. Renames don't require `sops updatekeys`
  since anchor names don't appear in ciphertext.
- **Backup:** host PQC identity files are stored in `passage` at
  `hosts/<host>/age.key` (analogous to `hosts/<host>/ssh_host_ed25519_key`).
  The admin identity lives in `passage` at `pki/ad_denai.key` — passage
  is the source of truth there, not a backup, since the workstation
  resolves it via `SOPS_AGE_KEY_CMD`.

## What changes in the repo

### Module / nix changes
- `hosts/*/sops.nix` (16 files): replace
  `age.sshKeyPaths = ["…/ssh_host_ed25519_key"];` with
  `age.keyFile = "…/sops/age.key";` — one file per host, landed in that
  host's cutover commit.
- No new top-level module is needed. sops-nix already supports `age.keyFile`;
  no PATH or plugin wiring required.
- Optional: a tiny `modules/common/sops-pqc.nix` that just sets `age.keyFile`
  based on a `common.sopsKeyLocation` enum (`bare-metal` | `guest`), so
  individual `sops.nix` files only need to import it. Worth it only if we
  feel the duplication; happy to skip and edit each file directly given
  there are 16.

### `.sops.yaml` changes
- Phase 1 adds two new anchors in the `keys:` section: `&ad_denai_pqc`
  (the new PQ admin recipient) — no rule references it yet.
- Each per-host commit in Phase 3:
  - Adds `&sv_<host>_pqc` to `keys:`.
  - Changes that host's `creation_rule` from
    `age: [*ad_denai, *sv_<host>]` to `age: [*ad_denai_pqc, *sv_<host>_pqc]`.
  - Deletes the now-unreferenced `&sv_<host>` (classical) anchor.
- The last host's commit also deletes the classical `&ad_denai` anchor —
  it has just become unreferenced.
- Optional cleanup commit at the end: rename `_pqc` suffixes back to plain
  names (`&sv_<host>_pqc` → `&sv_<host>`, `&ad_denai_pqc` → `&ad_denai`).
  No re-encryption needed since YAML anchor names don't appear in the
  encrypted output.

### Script changes
- `scripts/deploy-nixos-anywhere.sh`:
  - Drop the `ssh-to-age` derivation for the host's age recipient.
  - Generate a PQC identity for the host with `age-keygen -pq -o "$PQC_KEY"`,
    then derive the recipient with `age-keygen -y "$PQC_KEY"`.
  - Place the identity at `/persist/var/lib/sops-nix/key.txt` (mode 0400)
    via the existing `--extra-files` mechanism, parallel to how the SSH
    key is placed at `/persist/etc/ssh/ssh_host_ed25519_key`. Impermanence
    bind-mounts it to `/var/lib/sops-nix/key.txt` at boot.
  - Store the identity in passage at `hosts/$HOSTNAME/age.key`.
  - Keep the SSH host key generation as-is — it still serves SSH host
    identity, just no longer sops decryption.
  - The `.sops.yaml` anchor update logic stays the same; only the value
    differs.
- `scripts/setup-guest.sh`: parallel changes — generate a PQC identity for
  the guest, place at `/persist/guests/<guest>/static/var/lib/sops-nix/key.txt`
  (or via `--target` SSH push), passage-back at `hosts/<guest>/age.key`.
  The guest sees the file at `/static/var/lib/sops-nix/key.txt` via the
  virtiofs share.
- New helper script (or `nix run .#sops-pqc-rotate`): rotates a host's PQC
  identity in place — generates a new key, updates `.sops.yaml`, runs
  `sops updatekeys` on the host's secret files. Useful for the migration
  itself and for future rotations.

### Docs
- `docs/secrets.md` rewrite of "How It Works" and the registry table:
  drop the `ssh-to-age` derivation column, replace with "PQC identity path
  on host", recipient column shows `age1pq1...`. The "Action required"
  section for hosts missing `age.sshKeyPaths` becomes obsolete once
  every host is on `age.keyFile`.

## Phases

### Phase 0 — Toolchain verification (single commit, no deploys)
- Confirm `pkgs.sops` ≥ 3.12 in the current `nixpkgs` pin: `nix eval
  .#legacyPackages.x86_64-linux.sops.version` (or equivalent).
- Confirm `pkgs.age` ≥ 1.3.0 similarly.
- Confirm `sops-install-secrets` from sops-nix vendors a sufficiently recent
  `filippo.io/age` (check sops-nix's go.mod at the pinned commit). If not,
  bump sops-nix.
- Smoke test in a scratch dir on the workstation:
  - `age-keygen -pq -o /tmp/test.key`
  - `age-keygen -y /tmp/test.key` (prints the `age1pq1...` recipient)
  - Encrypt a small file to that recipient and decrypt with the identity.
  - Encrypt via sops with the recipient in `.sops.yaml`, decrypt with
    `SOPS_AGE_KEY_FILE=/tmp/test.key sops -d`.
- Exit criteria: native age PQC round-trips through both `age` and `sops`
  on this workstation. If anything fails, fix toolchain before continuing.

### Phase 1 — Admin PQC identity (local-only setup)

Precondition: `home/hosts/edith.nix` already sets
`home.sessionVariables.SOPS_AGE_KEY_CMD = "passage show pki/ad_denai.key"`
and the classical admin identity lives in that passage entry (the
passage-prelude commit). No `~/.config/sops/age/keys.txt` on the
workstation. This Phase does not touch `home/hosts/edith.nix` or
`SOPS_AGE_KEY_CMD` — only the passage entry contents and `.sops.yaml`.

1. Generate the admin PQC identity to a temp file:
   `age-keygen -pq -o /tmp/ad_denai_pqc.key`. Derive the recipient with
   `age-keygen -y /tmp/ad_denai_pqc.key` → `age1pq1...`.
2. Append the new identity to the existing `pki/ad_denai.key` passage
   entry. sops parses the entry contents the same way as a `keys.txt`
   file — multiple identities separated by a blank line work — so this
   becomes a multi-identity blob (classical + PQ) under the same path:
   ```bash
   { passage show pki/ad_denai.key; printf '\n'; cat /tmp/ad_denai_pqc.key; } \
     | passage insert -m -f pki/ad_denai.key
   shred -u /tmp/ad_denai_pqc.key
   ```
3. Add the new recipient as a second anchor in `.sops.yaml`'s `keys:`
   section, but do **not** reference it from any `creation_rule` yet:
   ```yaml
   - &ad_denai     age1mmqej3...     # classical, still used by all rules
   - &ad_denai_pqc age1pq1...        # new, no rule references it yet
   ```
4. Smoke test on a throwaway file: write a yaml, encrypt to
   `*ad_denai_pqc` only, then decrypt with sops. Confirm the PQ admin
   key works end-to-end. Also decrypt an existing classical-only file
   to confirm the multi-identity entry hasn't broken the classical path.
5. Commit (`.sops.yaml` only — no secret-file re-encryption, no
   home-manager change).

Exit criteria: PQ admin identity is appended to the `pki/ad_denai.key`
passage entry; the new anchor is declared in `.sops.yaml` but no
`creation_rule` uses it yet; sops invocations on the workstation have
both identities available via the unchanged `SOPS_AGE_KEY_CMD`.
Running hosts are unaffected.

### Phase 2 — Script and helper updates (single commit, no deploys)
- Update `scripts/deploy-nixos-anywhere.sh` and `scripts/setup-guest.sh` as
  described above. New hosts deployed from this point forward get a PQC
  identity by default.
- Add the `sops-pqc-rotate` helper (or document the manual recipe in
  `docs/secrets.md`).
- Land the optional `modules/common/sops-pqc.nix` helper if we want to
  reduce per-host `sops.nix` boilerplate.

Exit criteria: a hypothetical fresh deploy would produce a PQC-only host.
Existing hosts unaffected.

### Phase 3 — Per-host hard cutover
For each host, in the order below, do these steps in a single commit +
deploy cycle. The commit holds together because age refuses mixed
recipients: the host's secret files transition from "classical-only" to
"PQ-only" in one operation, with the new key file already on the host.

1. Locally: generate the host's PQC identity:
   `age-keygen -pq -o /tmp/<host>-age.key`, derive the recipient with
   `age-keygen -y /tmp/<host>-age.key`.
2. Place the identity at the right path on the host (the new generation
   that switches `sops.nix` to `age.keyFile` will look for it here):
   - Bare-metal: `scp` to `/persist/var/lib/sops-nix/key.txt`,
     `chmod 0400`, `chown root:root`. Impermanence bind-mounts
     `/persist/var/lib/sops-nix` onto `/var/lib/sops-nix` at boot — add
     `/var/lib/sops-nix` to the host's impermanence persisted-directories
     list if it isn't already covered.
   - Guest: `scp` to the parent at
     `/persist/guests/<guest>/static/var/lib/sops-nix/key.txt`, then on
     next guest reboot the static virtiofs share exposes it at
     `/static/var/lib/sops-nix/key.txt`.
3. Back up the identity to passage: `passage insert -m -f hosts/<host>/age.key`.
4. Update `.sops.yaml`:
   - Add `&sv_<host>_pqc age1pq1...` to the `keys:` section.
   - In that host's `creation_rule`, swap the anchor references from
     `[*ad_denai, *sv_<host>]` to `[*ad_denai_pqc, *sv_<host>_pqc]`.
   - Delete the now-unreferenced `&sv_<host>` (classical) anchor.
   - If this is the **last** host to migrate, also delete `&ad_denai`
     (which is no longer referenced by any rule).
5. Re-key the host's secret files (and any guest secret files if this
   commit batches a parent + its guests):
   `sops updatekeys --yes hosts/<host>/.../secrets/*.yaml`. sops decrypts
   with the local classical admin key and re-encrypts to
   `{ad_denai_pqc, sv_<host>_pqc}` — both PQ. No mixed-recipient state.
6. Update the host's `sops.nix`: change `age.sshKeyPaths = [...]` to
   `age.keyFile = "/var/lib/sops-nix/key.txt"` (or
   `"/static/var/lib/sops-nix/key.txt"` for guests).
7. `nixos-rebuild switch --flake .#<host> --target-host <host>` (or
   `deploy-rs`). Verify the new generation reaches `multi-user.target`,
   `sops-install-secrets` produces `/run/secrets/*` correctly, and the
   services that consume those secrets are running.
8. Commit.

Rollback if step 7 fails: `git revert` the commit (restores classical
ciphertext and `.sops.yaml`'s classical anchors for this host) and on the
host `nixos-rebuild --rollback`. The reverted commit and the prior
generation match — no mixed state ever existed. Re-deploy when fixed.

**Suggested host order** (lowest risk first; reorder freely):

1. **arcus** — single-host, no guests, lowest blast radius. Burn-in target.
2. **edith** (incus guest under calvard) — non-load-bearing personal box.
3. **calvard guests** — messeldam, basel, langport, tharbad, creil — in
   that order, batched as one commit each. langport carries WireGuard;
   verify its tunnels survive.
4. **erebonia guests** — roer, saint-arkh, trista.
5. **calvard** (parent) — taking calvard down for the cutover briefly stops
   its guests. Plan the window.
6. **erebonia** (parent) — same.
7. **liberl + its guests** (bose, ravennue, zeiss) — NFS host; takes ZFS
   shares offline for the reboot.
8. **phantasma** (microvm guest under thebeyond) — DNS resolver. Reboot
   degrades DNS until kresd on thebeyond falls back, which is the
   documented designed behavior.
9. **thebeyond** — last. Router. If anything goes wrong, everything is
   down. Have a console / out-of-band recovery path ready before deploying.

Admin identity handling during Phase 3: the `pki/ad_denai.key` passage
entry holds both the classical `ad_denai` identity and the new
`ad_denai_pqc` identity throughout (appended in Phase 1). The unchanged
`SOPS_AGE_KEY_CMD = "passage show pki/ad_denai.key"` emits both on
every sops invocation. The classical key is needed to decrypt files
for hosts that haven't migrated yet; the PQ key is needed to re-encrypt
files for hosts that just have. The classical `&ad_denai` anchor stays
in `.sops.yaml`'s `keys:` section as long as any unmigrated rule
references it; the last host's migration commit removes it.

Exit criteria: every host runs on `age.keyFile` with a PQ identity, every
secret file in the repo is encrypted to PQ recipients only, the classical
`&ad_denai` anchor is gone from `.sops.yaml`.

### Phase 4 — Admin classical identity archival
This phase is local-only; no host deploys. `SOPS_AGE_KEY_CMD` and
`home/hosts/edith.nix` are not touched — the change is entirely in the
contents of the `pki/ad_denai.key` passage entry.

1. Extract the classical half of the `pki/ad_denai.key` entry and
   store it at an archive path. The admin no longer needs it for
   routine work — every active secret file is PQ-only — but keep it
   available for forensic decryption of historic ciphertexts in git
   history:
   ```bash
   passage insert -m -f pki/archive/ad_denai_classical.key
   # paste the classical identity block only (comments + AGE-SECRET-KEY-1...),
   # then Ctrl-D
   ```
2. Trim `pki/ad_denai.key` to contain only the PQ identity:
   ```bash
   passage edit pki/ad_denai.key
   # delete the classical identity block, save
   ```
   `SOPS_AGE_KEY_CMD` is unchanged — the same command now emits only
   the PQ identity because the entry contents changed. Smoke-test
   `sops -d` on a PQ-encrypted secret.
3. Optional `.sops.yaml` cleanup commit: rename `&ad_denai_pqc` →
   `&ad_denai` and `&sv_<host>_pqc` → `&sv_<host>` throughout. Anchor
   names don't appear in encrypted output, so no `sops updatekeys` is
   needed — this is a pure rename for readability.

Exit criteria: classical admin identity is archived at
`pki/archive/ad_denai_classical.key` in passage; `pki/ad_denai.key`
contains only the PQ identity; `SOPS_AGE_KEY_CMD` and
`home/hosts/edith.nix` are unchanged from their passage-prelude state;
optional anchor-name cleanup landed.

### Phase 5 — Cleanup and docs
- Rewrite `docs/secrets.md` per the "Docs" section above.
- Remove `ssh-to-age` from the dependency check lists in
  `deploy-nixos-anywhere.sh` and `setup-guest.sh` (no longer needed).
- Search for any other references to `age.sshKeyPaths`, `ssh-to-age`, or
  the assumption that age recipients come from SSH keys; update.
- Confirm `nix flake check` (or `./scripts/run-checks.sh`) is clean.
- Note in `docs/secrets.md` how to rotate a host's PQC identity (the
  `sops-pqc-rotate` helper from Phase 2, or the manual recipe).

## Things to verify before starting

- **sops-install-secrets PQC support.** `sops-nix`'s on-host binary is what
  actually decrypts secrets at boot. Confirm the version we pin vendors a
  `filippo.io/age` ≥ 1.3.0. If not, bump the `sops-nix` flake input as
  part of Phase 0 — that's a one-line change but a real prerequisite.
- **deploy-rs / nixos-rebuild flow.** Confirm that on a host's first boot
  with the new generation, `sops-install-secrets.service` reads
  `/persist/sops/age.key` *before* anything that consumes `/run/secrets`
  starts. (sops-nix orders this correctly by default; verify on first
  cutover host.)
- **microvm `/static/` ordering.** The PQC key lives in the parent's
  `/persist/guests/<g>/static/` and is exposed via virtiofs. Confirm the
  guest's `sops-install-secrets.service` doesn't race the virtiofs mount.
  (Today's SSH key has the same dependency, so the ordering is already
  correct — this is verification, not new wiring.)
- **Impermanence `/var/lib/sops-nix` persistence.** Bare-metal hosts will
  need `/var/lib/sops-nix` (or just `/var/lib/sops-nix/key.txt`) added to
  the persistence list. The existing impermanence config persists
  `/etc/ssh/ssh_host_ed25519_key` (and friends) for the same reason;
  mirror that entry. Worth doing as part of Phase 2 in the common module
  so every host inherits it without per-host edits.

## Risks and mitigations

- **`sops-install-secrets` too old to read `age1pq1...`.** Caught in Phase
  0 verification before any host is touched.
- **Misplaced key on a host = bricked sops.** The host comes up but no
  secrets decrypt; services depending on them fail. Mitigation: hard
  rollback via `nixos-rebuild --rollback`. Place and verify the key file
  *before* the rebuild that switches `sops.nix` to `age.keyFile`.
- **thebeyond bricks the network.** Last in the order. Have console
  access (OOB) ready. Consider scheduling for a low-traffic window.
- **Lost PQC identity = lost host secrets.** Same threat model as the
  current SSH-derived key, but each host now has a *new* secret to back
  up. The passage backup at `hosts/<host>/age.key` is mandatory; the
  per-host commit (Phase 3 step 8) doesn't land until that backup exists
  (Phase 3 step 3).
- **Admin PQC key lost during Phase 1–3.** During this window the
  classical `ad_denai` is still a valid recipient for any unmigrated
  rule, so the admin keeps access to those files. Already-migrated rules
  would be unrecoverable without the PQ admin key. The PQ identity
  lives only as the appended half of the `pki/ad_denai.key` passage
  entry (no plaintext at rest on the workstation); the underlying risk
  reduces to the passage-store availability story, which is already
  load-bearing for `pki/ssh_host_ca_key`, `pki/fleet_x5c_ca_key`,
  every host's `disk.key`, etc.
- **No mixed-recipient files = no incremental fallback per file.** Once a
  host's secrets are re-keyed to PQ, the prior generation on that host
  (still on the SSH-derived key) cannot read them. Rollback is via
  `git revert` of the cutover commit (restoring the prior classical
  ciphertext) + `nixos-rebuild --rollback`. Both halves must move
  together — verify console/OOB access before deploying critical hosts.
- **age `-pq` format stability.** Native age PQC is part of the v1
  format; FiloSottile committed to backwards compatibility. This is a
  significantly safer bet than the experimental sntrup761 plugin.

## Out of scope

- PQC for SSH host authentication (no standard PQC host-key algorithm in
  OpenSSH yet). This plan does not touch `/etc/ssh/ssh_host_ed25519_key`
  or any SSH cert/CA wiring — they remain ed25519.
- PQC for `fleet_enrollment_key` (currently ED25519). Out of scope here;
  re-evaluate when the fleet TLS stack matures.
- Re-encryption of historical ciphertexts in git history. The classical
  admin identity remains recoverable from passage if old commits ever
  need to be inspected.

## Deliverables

- 1 commit: Phase 0 verification notes (or a `reports/pqc-toolchain-check.md`
  if findings warrant it).
- 1 commit: Phase 1 — admin PQC identity appended to the
  `pki/ad_denai.key` passage entry (out-of-band), `&ad_denai_pqc`
  anchor added to `.sops.yaml` (no rule references it yet). No
  home-manager change.
- 1 commit: Phase 2 — script + helper updates, common-module impermanence
  entry for `/var/lib/sops-nix`.
- ~13 commits: Phase 3 — one per host (or one per guest batch + parent).
  Each commit adds `&sv_<host>_pqc`, flips that rule's anchors, re-keys
  the host's secret files, drops the classical `&sv_<host>` anchor, and
  switches that host's `sops.nix` to `age.keyFile`. The last commit also
  drops `&ad_denai`.
- 0–1 commits: Phase 4 — passage entry surgery (extract classical to
  archive path, trim main entry to PQ-only) is out-of-band, no repo
  change. The only in-repo commit is the optional `.sops.yaml`
  anchor-name cleanup, if landed.
- 1 commit: Phase 5 — docs and cleanup.

Move this plan to `wip/` when Phase 0 lands; to `done/` when Phase 5 lands.
