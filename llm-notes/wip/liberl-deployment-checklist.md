# Liberl Deployment Checklist

Concrete, step-by-step checklist for reformatting the NAS (remiferia) to liberl
with btrfs+impermanence, preserving the ZFS data pool.

**Pre-conditions:**

- Off-site backup of ZFS data pool is complete (remiferia → external target)
- NixOS config for liberl is already in the repo and evaluates cleanly
- You have physical or IPMI console access (fallback if SSH breaks during kexec)

**Hardware:**

- Boot SSD: Samsung 860 EVO 250GB (`/dev/disk/by-id/ata-Samsung_SSD_860_EVO_250GB_S59WNJ0MC27735B`)
- ZFS pool: `data` on separate HDD(s) — **must not be touched**

---

## Phase 0: Pre-Reformat (on live remiferia)

These steps run on the currently-running remiferia system before any
destructive operations.

### 0.1 Verify ZFS pool layout

```bash
ssh root@remiferia
zfs list -r -o name,mountpoint,recordsize,compression data
```

Check whether child datasets already exist or if everything is flat under
`data`. If flat, proceed with 0.2. If datasets already exist, skip to 0.3.

### 0.2 Restructure ZFS datasets

Create child datasets for independent snapshot/compression policies. The
`data/media` dataset must remain a single dataset (no children) to preserve
hardlink support for the arr stack.

All existing data moves to `/data/old/` (a plain directory on the root
dataset) for later triage through the arr media ingestion pipelines. New
child datasets start empty.

```bash
# Move ALL existing data to an 'old' directory for later triage
mkdir -p /data/old
mv /data/media /data/old/media 2>/dev/null
mv /data/backup /data/old/backup 2>/dev/null
mv /data/drive /data/old/drive 2>/dev/null
# Move any other top-level directories
# ls /data/  to check for anything else, then:
# mv /data/<whatever> /data/old/<whatever>

# Create child datasets (all start empty)
zfs create -o mountpoint=/data/media -o recordsize=1M -o compression=lz4 data/media
zfs create -o mountpoint=/data/backup -o compression=zstd data/backup
zfs create -o mountpoint=/data/drive -o compression=zstd data/drive
```

**Compression rationale:** `lz4` for media — near-zero overhead on
already-compressed video/audio (detects incompressibility and skips), but
still compresses metadata, subtitles, NFOs, and other small files alongside
media. `zstd` for backup/drive where compression ratio matters more.

**Data triage plan:** The old data in `/data/old/` stays on the root
dataset. Over time, ingest media through the arr stack (Sonarr/Radarr),
move general files to `/data/drive/`, and delete what's no longer needed.
No urgency — the old data doesn't interfere with anything.

### 0.3 Verify dataset structure

```bash
zfs list -r -o name,mountpoint,recordsize,compression data
```

Expected:

```
NAME          MOUNTPOINT     RECSIZE  COMPRESS
data          /data          128K     on
data/backup   /data/backup   128K     zstd
data/drive    /data/drive    128K     zstd
data/media    /data/media    1M       lz4
```

Verify `data/media` has no child datasets:

```bash
zfs list -r data/media   # must show exactly one row
```

Verify old data is intact:

```bash
ls /data/old/
du -sh /data/old/   # sanity check size
```

### 0.4 Create media directory structure

```bash
# Create staging directories for the arr pipeline
mkdir -p /data/media/{torrents,usenet/complete,manual,library}/{movies,tv,music}

# Set ownership to media user (UID/GID 400 from centralized registry)
chown -R 400:400 /data/media
```

### 0.5 Stop services and export ZFS pool

```bash
# Stop all microvm guests
systemctl stop microvm@ardent   # or zeiss if already renamed
systemctl stop microvm@monrain  # if still present

# Stop NFS and Samba
systemctl stop nfs-server
systemctl stop smbd nmbd

# Export the ZFS pool cleanly
zpool export data
zpool status   # should report no pools imported
```

### 0.6 Note disk identifiers

Before losing access to the running system, confirm the boot SSD device path:

```bash
ls -la /dev/disk/by-id/ | grep -v part | grep Samsung
# Should show: ata-Samsung_SSD_860_EVO_250GB_S59WNJ0MC27735B
```

Confirm which disks belong to the ZFS pool:

```bash
# Pool is already exported, but the disk labels remain visible
lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL | grep -v loop
```

Record these — you'll verify them after kexec to confirm disko targets
only the correct disk.

---

## Phase 1: Deploy with nixos-anywhere

### 1.1 Place backed-up SSH keys

Reuse the existing remiferia SSH host key and guest keys. Copy from your
backup to `.keys/` with the new names so the deploy script finds and reuses
them (no sops re-encryption needed):

```bash
# Host key (remiferia → liberl)
cp <backup>/remiferia-ssh_host_ed25519_key .keys/liberl-ssh_host_ed25519_key
cp <backup>/remiferia-ssh_host_ed25519_key.pub .keys/liberl-ssh_host_ed25519_key.pub
chmod 600 .keys/liberl-ssh_host_ed25519_key

# Guest keys (ardent → zeiss, reuse existing name if backup uses old names)
cp <backup>/ardent-ssh_host_ed25519_key .keys/zeiss-ssh_host_ed25519_key
cp <backup>/ardent-ssh_host_ed25519_key.pub .keys/zeiss-ssh_host_ed25519_key.pub
chmod 600 .keys/zeiss-ssh_host_ed25519_key

# LUKS disk key (if you have remiferia's, reuse it; otherwise a new one is generated)
cp <backup>/remiferia-disk.key .keys/liberl-disk.key 2>/dev/null || true
chmod 600 .keys/liberl-disk.key 2>/dev/null || true
```

The deploy script checks `.keys/<hostname>-*` before generating new keys.
If a key file exists, it reuses it and skips generation. Since the age key
in `.sops.yaml` was derived from remiferia's SSH key and we're reusing
that key, no sops re-encryption is needed.

**Note:** bose is a new guest with no prior key — the deploy script
(via `setup-guest.sh`) will generate a fresh key for it automatically.

### 1.2 Run the deploy script

```bash
# From the repo root, on the deployment machine (edith, angbar, etc.)
./scripts/deploy-nixos-anywhere.sh liberl root@<remiferia-current-ip>
```

The script will:

1. Detect the btrfs disko profile
2. Generate (or reuse) SSH host key + LUKS disk key
3. Derive age key, update `.sops.yaml` if changed
4. Re-encrypt sops secrets for liberl + guests (zeiss, bose)
5. Run `setup-guest.sh` for zeiss and bose (SSH keys, sops, host certs)
6. Sign SSH host certificates
7. **Phase 1 (kexec + disko):** kexec into installer, partition boot SSD
8. **Phase 2 (btrfs):** Create `@blank` snapshot for impermanence rollback
9. **Phase 3 (install):** Install NixOS with extra-files (SSH keys, guest dirs, LUKS key)

**Critical safety check during the script:** When the "DESTROY ALL DATA"
warning appears, the script is about to reformat only the boot SSD specified
in the disko profile (`ata-Samsung_SSD_860_EVO_250GB_...`). The ZFS HDDs
are separate devices and will not be touched by disko.

### 1.3 If the deploy script cannot be used

If nixos-anywhere can't reach the target (network issues, kexec problems),
fall back to manual installation:

1. Boot from NixOS installer USB
2. Verify disk layout: `lsblk -o NAME,SIZE,TYPE,FSTYPE,MODEL`
3. **Do NOT import the ZFS pool yet** — disko needs a clean environment
4. Place the LUKS keyfile:
   ```bash
   mkdir -p /tmp && echo "<keyfile-contents>" > /tmp/secret.key
   ```
5. Run disko:
   ```bash
   nix run github:nix-community/disko -- --mode disko /path/to/config
   ```
6. Create `@blank` snapshot:
   ```bash
   mkdir -p /tmp/btrfs-root
   mount /dev/mapper/cryptroot /tmp/btrfs-root -o subvolid=5
   btrfs subvolume snapshot -r /tmp/btrfs-root/@root /tmp/btrfs-root/@blank
   umount /tmp/btrfs-root
   ```
7. Place SSH keys and guest files into `/mnt/persist/`
8. Install: `nixos-install --flake /path/to/repo#liberl --no-root-passwd`
9. Place LUKS keyfile at `/mnt/boot/secrets/disk.key`
10. Reboot

---

## Phase 2: Post-Install Verification

After the first boot into the new liberl system.

### 2.1 Verify btrfs + impermanence

```bash
ssh root@liberl   # may need to use IP if DNS hasn't updated

# Verify btrfs root
findmnt /          # should show /dev/mapper/cryptroot, btrfs, subvol=/@root
findmnt /persist   # should show /dev/mapper/cryptroot, btrfs, subvol=/@persist
findmnt /nix       # should show /dev/mapper/cryptroot, btrfs, subvol=/@nix
findmnt /boot      # should show ESP partition, vfat

# Verify impermanence is active
ls /persist/       # should have etc/ssh/, guests/, etc.
```

### 2.2 Verify ZFS pool

```bash
# Pool should auto-import via boot.zfs.extraPools
zpool status data
zfs list -r data

# If pool did not auto-import:
zpool import data
```

Verify datasets and mountpoints:

```bash
ls /data/media /data/backup /data/drive
```

### 2.3 Add L2ARC cache

The disko profile created a raw L2ARC partition on the boot SSD. Add it to
the ZFS pool as a cache device:

```bash
# Identify the L2ARC partition
lsblk -o NAME,SIZE,TYPE,PARTLABEL /dev/disk/by-id/ata-Samsung_SSD_860_EVO_250GB_*
# Look for the partition labeled "l2arc"

# Add as cache device (use the by-id path for stability)
zpool add data cache /dev/disk/by-id/ata-Samsung_SSD_860_EVO_250GB_S59WNJ0MC27735B-part2

# Verify
zpool status data   # should show cache device
```

### 2.4 Verify sops secrets

```bash
systemctl status sops-nix
ls /run/secrets/
cat /run/secrets/upsmon.password   # should decrypt successfully
```

### 2.5 Verify networking

```bash
# Host IP on vINFRA (VLAN 11)
ip addr show enp4s0.11
# Should show 10.97.11.20 (or whatever liberl's IP is)

# DNS resolution
resolvectl query phantasma.internal
resolvectl query basel.internal

# VLAN bridges for guests
ip link show br20 br21 br100
```

### 2.6 Verify SSH host certificate

```bash
# Check cert exists and is valid
ssh-keygen -L -f /etc/ssh/ssh_host_ed25519_key-cert.pub
# Principals should include liberl.internal.mutantmell.net, liberl.internal, etc.
```

---

## Phase 3: Guest Verification

### 3.1 Verify guest directory structure

```bash
ls -la /persist/guests/zeiss/static/etc/ssh/
ls -la /persist/guests/bose/static/etc/ssh/
# Both should have ssh_host_ed25519_key + .pub
```

### 3.2 Start and verify zeiss (Attic binary cache)

```bash
systemctl start microvm@zeiss
systemctl status microvm@zeiss

# SSH into guest
ssh root@zeiss.internal

# Inside zeiss:
systemctl status attic
curl -k https://localhost/   # Attic should respond
```

### 3.3 Start and verify bose (arr stack)

```bash
systemctl start microvm@bose
systemctl status microvm@bose

# SSH into guest
ssh root@bose.internal

# Inside bose:
systemctl status sonarr radarr bazarr

# Verify media virtiofs mount
ls /media/
ls /media/library/ /media/manual/ /media/torrents/

# Verify web UIs are accessible (from trusted VLAN)
curl http://bose.internal:8989   # Sonarr
curl http://bose.internal:7878   # Radarr
curl http://bose.internal:6767   # Bazarr
```

---

## Phase 4: NAS Services Verification

### 4.1 Verify NFS exports

```bash
showmount -e localhost
# Expected:
#   /export/rw/media  <erebonia-ip>
#   /export/ro/media  <calvard-ip>
```

Test from calvard:

```bash
ssh root@calvard
mount | grep media   # should show NFS mount from liberl
ls /mnt/media/library/
```

Test from erebonia:

```bash
ssh root@erebonia
mount | grep media
touch /mnt/media/test-write && rm /mnt/media/test-write   # RW should work
```

### 4.2 Verify Samba shares

From a Windows machine on the trusted VLAN:

- Browse to `\\LIBERL\` — should show `drive`, `media`, `backup` shares
- Verify read/write access with the `mutantmell` user

### 4.3 Verify UPS monitoring

```bash
upsc apc
# Should show UPS status (battery charge, status, etc.)
```

### 4.4 Verify Prometheus exporters

```bash
curl http://localhost:9001/metrics   # node_exporter
curl http://localhost:9002/metrics   # zfs_exporter
curl http://localhost:9003/metrics   # smartctl_exporter
```

Check tharbad's Prometheus targets page to confirm liberl + zeiss + bose
are all being scraped successfully.

### 4.5 Verify promtail log shipping

```bash
systemctl status promtail
# Check Loki on tharbad for logs from liberl, zeiss, bose
```

---

## Phase 5: Commit + Cleanup

### 5.1 Fetch hardware config

If the hardware-configuration.nix needs updating after install:

```bash
ssh root@liberl 'nixos-generate-config --no-filesystems --show-hardware-config'
# Compare with hosts/liberl/hardware-configuration.nix, update if different
```

### 5.2 Commit changes

Since we're reusing the host and zeiss keys, the deploy script will only
modify files related to the new bose guest and host cert re-signing:

- `lib/common/data/keys.json` (host public keys — confirms existing, adds bose)
- `lib/common/data/host-certs/` (SSH host certificates — re-signed)
- `hosts/liberl/microvm/guests/bose/secrets/` (new guest sops secrets, if any)
- `.sops.yaml` (new bose guest age key + creation rule)

Commit all changes together.

### 5.3 Update monitoring references

Verify that tharbad's Prometheus config already references `liberl` (not
`remiferia`) and includes `zeiss` and `bose` as scrape targets. If the
rename was completed in a prior commit, this should already be correct.

### 5.4 Update DNS transition aliases

The network registry has transition aliases mapping `remiferia.internal` →
`liberl`. These can be removed once all consumers have been updated and
tested with the new name. Leave them for now; schedule removal after a
soak period.

### 5.5 Backup the LUKS key

The deploy script saves keys to `.keys/` (gitignored). Ensure these are
backed up to a secure location:

- `.keys/liberl-disk.key` — LUKS encryption key (loss = data loss on boot SSD)
- `.keys/liberl-ssh_host_ed25519_key` — SSH host private key

---

## Rollback Plan

If something goes wrong during deployment:

**Before kexec (Phase 1.2):** Just cancel. Nothing has changed.

**After disko but before install:** Boot SSD is reformatted but ZFS pool
is untouched. Boot from USB installer, import ZFS pool (`zpool import data`),
verify data integrity. Re-run the install phase or restore the old system
from backup.

**After install but guests don't work:** The guest disk images are
auto-created on first start. If there are issues, delete the images from
`/persist/guests/*/images/` and let them recreate. Re-run `setup-guest.sh`
if SSH keys are wrong.

**ZFS pool doesn't import:** This would indicate the pool metadata is
damaged (unlikely since disko doesn't touch it). Use `zpool import -f data`
to force import. If that fails, restore from the off-site backup.

---

## Sequence Diagram

```
Live remiferia                     Deploy machine
─────────────                      ──────────────
  │                                     │
  │  0.2 Move data to /data/old/,      │
  │      create child datasets          │
  │  0.4 Create media dirs + chown     │
  │  0.5 Stop services, export pool    │
  │  0.6 Note disk IDs                 │
  │                                     │
  │                 1.1 Place keys ────►│
  │                     in .keys/       │
  │                                     │
  │◄─────── 1.2 deploy-nixos-anywhere ─┤
  │         (kexec into installer)      │
  │                                     │
  │  [installer running in RAM]         │
  │  disko partitions boot SSD only     │
  │  @blank snapshot created            │
  │  NixOS installed + extra-files      │
  │                                     │
  │  ── reboot ──                       │
  │                                     │
New liberl                              │
──────────                              │
  │                                     │
  │  2.1 Verify btrfs + impermanence   │
  │  2.2 Verify ZFS pool auto-import   │
  │  2.3 Add L2ARC cache               │
  │  2.4-2.6 Verify sops, net, certs   │
  │  3.x Verify guests                 │
  │  4.x Verify NAS services           │
  │                                     │
  │                     5.x Commit ────►│
```
