# Plan: Staged Migration Rollout

## Overview

Deploy the updated NixOS configurations in a safe, staged sequence.
The interim router (not managed in this repo) provides VLAN 10/11/20/100
but has no internal DNS host entries.

**Sequence:** calvard -> remiferia (in-place) -> erebonia (blocked on switch config)

## Current State

| Host           | Current IP                    | Config Target IP                          | Role    | Status                   |
| -------------- | ----------------------------- | ----------------------------------------- | ------- | ------------------------ |
| calvard        | unused (wiped)                | 10.97.11.30 + 10.0.11.30 (VLAN 11)        | VM host | Ready for nixos-anywhere |
| remiferia      | 10.0.10.32 (VLAN 10 untagged) | 10.97.11.20 + 10.0.11.20 (VLAN 11 tagged) | NAS     | In-place update required |
| erebonia       | unused (wiped)                | 10.97.11.31 + 10.0.11.31 (VLAN 11)        | VM host | Blocked on ZyXEL switch  |
| interim router | manages VLANs 10/11/20/100    | N/A                                       | Gateway | No internal DNS          |

## Pre-deployment Blockers

### Blocker 1: Interim router DNS host entries

The interim OpenWrt router runs dnsmasq but has no static host records for
internal hosts. Without DNS, hosts can't resolve each other by name.

**Options (pick one at deploy time):**

A. **Manual dnsmasq config on router** — SSH to the router and add
`/etc/hosts` or dnsmasq `address=` entries for the hosts being deployed.
Minimum entries needed per phase:

- Phase 1 (calvard): `10.0.11.30 calvard.internal` (and any guests)
- Phase 2 (remiferia): `10.0.11.20 remiferia.internal`
- All entries need both 10.97 and 10.0 addresses

B. **Use IP addresses directly** — Skip DNS entirely during bootstrap.
Configure calvard/remiferia to use IPs instead of hostnames for
cross-host references (NFS mounts, prometheus targets, etc.).
Less clean but avoids router changes.

C. ~~Deploy phantasma (Unbound) on calvard first~~ — Not viable.
Phantasma is a thebeyond guest, and thebeyond hardware is months away.

**Recommendation:** Use (A) for the entire rollout. The full `/etc/hosts`
block is provided below — paste it once and it covers all phases.

**Full /etc/hosts block for the interim router** (generated from network registry,
will not change between now and rollout):

```
# --- Parent hosts (VLAN 11 management) ---
10.97.11.1  thebeyond.internal.mutantmell.net thebeyond.internal
10.0.11.1   thebeyond.internal.mutantmell.net thebeyond.internal
10.97.11.20 remiferia.internal.mutantmell.net remiferia.internal
10.0.11.20  remiferia.internal.mutantmell.net remiferia.internal
10.97.11.30 calvard.internal.mutantmell.net calvard.internal
10.0.11.30  calvard.internal.mutantmell.net calvard.internal
10.97.11.31 erebonia.internal.mutantmell.net erebonia.internal
10.0.11.31  erebonia.internal.mutantmell.net erebonia.internal

# --- VLAN 11 microVM guests (management) ---
10.97.11.2  phantasma.internal.mutantmell.net phantasma.internal
10.0.11.2   phantasma.internal.mutantmell.net phantasma.internal
10.97.11.3  roer.internal.mutantmell.net roer.internal
10.0.11.3   roer.internal.mutantmell.net roer.internal
10.97.11.4  legram.internal.mutantmell.net legram.internal
10.0.11.4   legram.internal.mutantmell.net legram.internal
10.97.11.5  ymir.internal.mutantmell.net ymir.internal
10.0.11.5   ymir.internal.mutantmell.net ymir.internal
10.97.11.6  edith.internal.mutantmell.net edith.internal
10.0.11.6   edith.internal.mutantmell.net edith.internal
10.97.11.7  basel.internal.mutantmell.net basel.internal
10.0.11.7   basel.internal.mutantmell.net basel.internal

# --- VLAN 20 guests (trusted) ---
10.97.20.40 denai.internal.mutantmell.net denai.internal
10.0.20.40  denai.internal.mutantmell.net denai.internal
10.97.20.41 tharbad.internal.mutantmell.net tharbad.internal
10.0.20.41  tharbad.internal.mutantmell.net tharbad.internal
10.97.20.42 messeldam.internal.mutantmell.net messeldam.internal
10.0.20.42  messeldam.internal.mutantmell.net messeldam.internal

# --- VLAN 100 guests (dmz) ---
10.97.100.31 ardent.internal.mutantmell.net ardent.internal
10.0.100.31  ardent.internal.mutantmell.net ardent.internal
10.97.100.32 monrain.internal.mutantmell.net monrain.internal
10.0.100.32  monrain.internal.mutantmell.net monrain.internal
10.97.100.40 ordis.internal.mutantmell.net ordis.internal
10.0.100.40  ordis.internal.mutantmell.net ordis.internal
10.97.100.41 langport.internal.mutantmell.net langport.internal
10.0.100.41  langport.internal.mutantmell.net langport.internal
10.97.100.50 heimdallr.internal.mutantmell.net heimdallr.internal
10.0.100.50  heimdallr.internal.mutantmell.net heimdallr.internal
10.97.100.51 trista.internal.mutantmell.net trista.internal
10.0.100.51  trista.internal.mutantmell.net trista.internal
10.97.100.52 oracion.internal.mutantmell.net oracion.internal
10.0.100.52  oracion.internal.mutantmell.net oracion.internal
10.97.100.53 creil.internal.mutantmell.net creil.internal
10.0.100.53  creil.internal.mutantmell.net creil.internal
10.97.100.61 saint-arkh.internal.mutantmell.net saint-arkh.internal
10.0.100.61  saint-arkh.internal.mutantmell.net saint-arkh.internal

# --- VLAN 10 (network devices) ---
10.97.10.12 arseille.internal.mutantmell.net arseille.internal
10.0.10.12  arseille.internal.mutantmell.net arseille.internal

# --- VLAN 31 (adu) ---
10.97.31.20 glorious.internal.mutantmell.net glorious.internal
10.0.31.20  glorious.internal.mutantmell.net glorious.internal

```

IPv6 (ULA) entries omitted — the interim router does not route ULA.
dnsmasq on the router will serve these from `/etc/hosts` automatically
when `expandhosts` and `localise_queries` are enabled.

### Blocker 2: Switch port configuration for remiferia

Remiferia currently connects via VLAN 10 (untagged). The new config expects
VLAN 11 (tagged) on `enp4s0`. The switch port serving remiferia must be
reconfigured to tag VLAN 11 traffic before the NAS update.

**Pre-check:** Verify the switch already passes VLAN 11 tagged frames to
remiferia's port. If not, configure it via the switch management interface
before starting Phase 2.

### Blocker 3: erebonia switch (ZyXEL GS1900-10HP)

Erebonia is on a different switch that doesn't yet handle VLAN 11.
This switch needs to be imported into the repository and configured.
Erebonia deployment is blocked until this is done.

---

## Phase 1: Deploy calvard (nixos-anywhere)

### Prerequisites

- Switch port for calvard passes VLAN 11 tagged traffic
- Interim router has DNS entry for calvard (or use IPs)
- Boot calvard into NixOS installer / kexec image

### Steps

1. **Run the deploy script:**

   ```bash
   ./scripts/deploy-nixos-anywhere.sh calvard root@<calvard-installer-ip>
   ```

   This handles: disko partitioning, ZFS encryption, SSH key generation,
   guest SSH keys, sops re-encryption, NixOS install.

2. **Reboot and unlock ZFS** via SSH on port 2222:

   ```bash
   ssh -p 2222 root@10.0.11.30
   # Enter ZFS passphrase when prompted
   ```

3. **Verify host is up:**
   - SSH to `root@10.0.11.30` (or `calvard.internal` if DNS is configured)
   - Check `systemctl status` for failed units
   - Verify VLAN 11 connectivity: `ip addr show enp88s0.11`
   - Verify bridges: `bridge link show`

4. **Populate guest secrets:**
   - Replace placeholder values in guest `secrets.yaml` files with real secrets
   - Run `sops hosts/calvard/microvm/guests/<guest>/secrets/secrets.yaml` for each guest
   - Services will start once secrets are populated

5. **Start microVM guests:**
   - MicroVMs should auto-start if configured
   - Check: `machinectl list` or `systemctl status microvm@*`
   - Verify guest networking (each guest should get its VLAN IP)

6. **Set up Incus guest (messeldam):**
   - Run post-boot Incus SSH key push script
   - Verify messeldam starts and gets IP 10.97.20.42

7. **Note:** phantasma (Unbound DNS) is a thebeyond guest, not calvard.
   It won't be available until thebeyond hardware arrives. Internal DNS
   must come from manual router `/etc/hosts` entries for the entire rollout.

### Rollback

Calvard is a fresh install on a wiped machine. If it fails, reboot into
the installer and re-run the deploy script. No data at risk.

---

## Phase 2: Update remiferia (in-place nixos-rebuild)

This is the riskiest phase. Remiferia is the NAS with live ZFS data pools
and is currently the machine running claude-code.

### Why in-place (not nixos-anywhere)

- nixos-anywhere would **destroy the ZFS data pools** (disko reformats disks)
- remiferia uses traditional ext4 for the OS, with a separate `data` ZFS pool
- `nixos-rebuild switch` updates the OS config without touching the data pool
- The `boot.zfs.extraPools = [ "data" ]` config will import the existing pool

### Risk analysis

| Risk                               | Impact                      | Mitigation                                                                            |
| ---------------------------------- | --------------------------- | ------------------------------------------------------------------------------------- |
| Network change breaks connectivity | Lose SSH to NAS             | Pre-configure switch; have physical/IPMI access                                       |
| ZFS pool fails to import           | Data inaccessible           | Pool name (`data`) matches config; test with `zpool status` first                     |
| NFS exports break                  | Clients lose mounts         | New config exports on both 10.97 + 10.0 subnets (dual-stack)                          |
| Samba breaks                       | Windows clients lose shares | Config preserves shares + JOTUNHEIMR alias                                            |
| Claude-code session dies           | Lose working session        | Move session to calvard first                                                         |
| Services fail to start             | NAS partially down          | Select previous generation in boot menu, or `nixos-rebuild boot --rollback && reboot` |

### Prerequisites

- [ ] calvard is deployed and stable (Phase 1 complete)
- [ ] Move claude-code session off remiferia to calvard (or a laptop)
- [ ] Switch port for remiferia configured for VLAN 11 tagged traffic
- [ ] Physical or IPMI console access to remiferia (in case network breaks)
- [ ] Verify `data` ZFS pool health: `zpool status data`
- [ ] Take a ZFS snapshot of critical datasets: `zfs snapshot -r data@pre-migration`
- [ ] DNS entry for remiferia on interim router (or phantasma running on calvard)
- [ ] Copy the updated flake to remiferia (git pull or scp)

### Steps

1. **Pre-flight checks on remiferia (via current 10.0.10.32 connection):**

   ```bash
   # Verify ZFS pool health
   zpool status data
   # Snapshot everything
   zfs snapshot -r data@pre-migration
   # Verify current NFS exports are working
   showmount -e localhost
   # Note current mount clients
   ss -tn state established '( dport = :2049 )'
   ```

2. **Prepare the switch:**
   - Configure remiferia's switch port to pass VLAN 11 tagged traffic
   - Keep VLAN 10 untagged on the same port (so current connectivity survives)
   - Verify: remiferia should still be reachable at 10.0.10.32

3. **Test the new config builds cleanly:**

   ```bash
   cd /path/to/dotfiles
   nixos-rebuild build --flake .#remiferia
   ```

   This builds without applying. If it fails, fix config issues before proceeding.

   **Note:** remiferia's current NixOS is very old. If `nixos-rebuild` fails
   due to an outdated Nix version, enter a shell with a newer Nix first:

   ```bash
   nix shell nixpkgs#nix -c nixos-rebuild build --flake .#remiferia
   ```

   Alternatively, build the closure on calvard and copy it to remiferia
   via `nix copy`.

4. **Apply the update (point of no return for network config):**

   ```bash
   nixos-rebuild boot --flake .#remiferia
   reboot
   ```

   Using `boot` instead of `switch` — given the volume of changes (network
   migration, systemd-networkd, firewall, services), a clean boot into the
   new config is safer than live-switching all services at once.

   **What changes on reboot:**
   - Network: VLAN 10 untagged -> VLAN 11 tagged on enp4s0
   - IP: 10.0.10.32 -> 10.97.11.20 + 10.0.11.20
   - SSH session on 10.0.10.32 will drop
   - New SSH endpoint: 10.0.11.20 or 10.97.11.20

5. **Reconnect and verify:**

   ```bash
   ssh root@10.0.11.20  # or 10.97.11.20
   # Verify networking
   ip addr show enp4s0.11
   # Verify ZFS pool imported
   zpool status data
   # Verify NFS exports
   showmount -e localhost
   # Verify Samba
   systemctl status smbd nmbd
   # Verify prometheus exporters
   curl -s http://localhost:9001/metrics | head
   curl -s http://localhost:9002/metrics | head
   ```

6. **Verify NFS clients can mount:**
   - From calvard: test NFS mount of remiferia exports
   - Check both 10.97 and 10.0 addresses work in exports

7. **Start microVM guests (ardent, monrain):**
   - Check auto-start and guest networking
   - Handle denai cleanup (slated for removal)

8. **Clean up old VLAN 10 config on switch:**
   - Once everything is verified working on VLAN 11
   - Remove VLAN 10 untagged from remiferia's switch port

### Rollback plan

**If network breaks (can't SSH in):**

- Access via physical console or IPMI
- Select the previous generation from the systemd-boot menu, or
  `nixos-rebuild boot --rollback && reboot`
- This restores VLAN 10 untagged networking

**If ZFS pool won't import:**

- The pool name `data` hasn't changed; `extraPools = [ "data" ]` matches
- Manual import: `zpool import data`
- If pool is damaged (unlikely from config change): restore from snapshots

**If NFS exports break but host is reachable:**

- Check `exportfs -v` for active exports
- Verify firewall allows NFS: `nft list ruleset | grep 2049`
- The new config allows both 10.97 and 10.0 subnets, so old clients should work

---

## Phase 3: Deploy erebonia (nixos-anywhere) — BLOCKED

### Blocker

ZyXEL GS1900-10HP switch must be imported into the repository and configured
to pass VLAN 11 tagged traffic to erebonia's port.

### Prerequisites

- [ ] ZyXEL switch config added to repository
- [ ] VLAN 11 configured on erebonia's switch port
- [ ] DNS entries for erebonia (via phantasma or manual)
- [ ] erebonia `sops.nix` created (currently missing)

### Steps

Same pattern as Phase 1 (calvard), using:

```bash
./scripts/deploy-nixos-anywhere.sh erebonia root@<erebonia-installer-ip>
```

Erebonia-specific post-deploy:

- NFS mounts from remiferia (`/mnt/data`, `/mnt/media`) should auto-mount
- Verify NFS connectivity to remiferia at new IP
- Start microVM guests (roer, legram, ymir, heimdallr, ordis, saint-arkh)
- Set up Incus guest (trista)

### Rollback

Same as calvard — fresh install on wiped machine, re-run deploy script.

---

## Phase 4: Post-migration cleanup

After all three hosts are deployed and stable:

1. **Remove legacy 10.0.x.x addresses** — Once all clients use 10.97:
   - Remove `cidr4Legacy` / `subnet4Legacy` from network registry
   - Remove dual-address configs from host network configs
   - Remove legacy firewall rules

2. **Remove VLAN 10 from switches** — No longer needed

3. **Remove backward-compat aliases:**
   - JOTUNHEIMR netbios alias on remiferia
   - yggdrasil.local / jotunheimr.local DNS aliases

4. **Decommission old erebonia guests** — Once calvard replacements are verified:
   - roer -> edith (Keycloak)
   - legram -> basel (step-ca)
   - ymir -> tharbad (monitoring)
   - ordis -> langport (reverse proxy)
   - heimdallr -> oracion (Jellyfin)

5. **Remove denai guest** from remiferia (already slated for removal)

6. **Remove remiferia pre-migration ZFS snapshot:**
   ```bash
   # Dry-run first — verify this only lists snapshots, not datasets
   zfs destroy -r -n -v data@pre-migration
   # Then destroy for real
   zfs destroy -r data@pre-migration
   ```
   This removes only the snapshot (not the underlying data). Must be done
   before pruning datasets, otherwise the snapshot holds references to
   deleted blocks and disk space won't be reclaimed.

---

## Quick Reference: Key IPs

| Host      | Current    | Target (10.97) | Target (10.0 legacy) | VLAN |
| --------- | ---------- | -------------- | -------------------- | ---- |
| calvard   | none       | 10.97.11.30    | 10.0.11.30           | 11   |
| remiferia | 10.0.10.32 | 10.97.11.20    | 10.0.11.20           | 11   |
| erebonia  | none       | 10.97.11.31    | 10.0.11.31           | 11   |
| phantasma | none       | 10.97.11.2     | 10.0.11.2            | 11   |

## Quick Reference: Deploy commands

```bash
# Phase 1
./scripts/deploy-nixos-anywhere.sh calvard root@<ip>

# Phase 2 (from remiferia itself)
nixos-rebuild build --flake .#remiferia   # test first
nixos-rebuild boot --flake .#remiferia   # stage config, then reboot

# Phase 3
./scripts/deploy-nixos-anywhere.sh erebonia root@<ip>
```
