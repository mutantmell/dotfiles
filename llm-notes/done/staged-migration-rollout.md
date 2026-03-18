# Plan: Staged Migration Rollout

## Overview

Deploy the updated NixOS configurations in a safe, staged sequence.
The interim router (not managed in this repo) provides VLAN 10/11/20/100
but has no internal DNS host entries.

**Sequence:** calvard -> remiferia (in-place) -> internal services (messeldam/langport) -> erebonia

## Current State

| Host           | Current IP                 | Config Target IP      | Role    | Status                  |
| -------------- | -------------------------- | --------------------- | ------- | ----------------------- |
| calvard        | 10.97.11.30 (VLAN 11)      | 10.97.11.30 (VLAN 11) | VM host | **Deployed**            |
| remiferia      | 10.97.11.20 (VLAN 11)      | 10.97.11.20 (VLAN 11) | NAS     | **Deployed**            |
| erebonia       | 10.97.11.31 (VLAN 11)      | 10.97.11.31 (VLAN 11) | VM host | **Deployed**            |
| interim router | manages VLANs 10/11/20/100 | N/A                   | Gateway | Serves 10.97 + legacy   |

**Note:** Legacy 10.0.x.x addresses have been removed from all NixOS configurations
(2026-03-15). The interim router still serves both ranges for DHCP compatibility with
non-NixOS clients, but all NixOS hosts and guests now use only 10.97.x.x.

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

**Full /etc/hosts block for the interim router** (10.97 only — legacy 10.0
addresses removed from all NixOS configs as of 2026-03-15):

```
# --- Parent hosts (VLAN 11 management) ---
10.97.11.1  thebeyond.internal.mutantmell.net thebeyond.internal
10.97.11.20 remiferia.internal.mutantmell.net remiferia.internal
10.97.11.30 calvard.internal.mutantmell.net calvard.internal
10.97.11.31 erebonia.internal.mutantmell.net erebonia.internal

# --- VLAN 11 microVM guests (management) ---
10.97.11.2  phantasma.internal.mutantmell.net phantasma.internal
10.97.11.6  messeldam.internal.mutantmell.net messeldam.internal
10.97.11.7  basel.internal.mutantmell.net basel.internal

# --- VLAN 20 guests (trusted) ---
10.97.20.41 tharbad.internal.mutantmell.net tharbad.internal
10.97.20.42 edith.internal.mutantmell.net edith.internal
10.97.20.50 azoth.internal.mutantmell.net azoth.internal

# --- VLAN 100 guests (dmz) ---
10.97.100.31 ardent.internal.mutantmell.net ardent.internal
10.97.100.32 monrain.internal.mutantmell.net monrain.internal
10.97.100.41 langport.internal.mutantmell.net langport.internal
10.97.100.51 trista.internal.mutantmell.net trista.internal
10.97.100.52 oracion.internal.mutantmell.net oracion.internal
10.97.100.53 creil.internal.mutantmell.net creil.internal
10.97.100.61 saint-arkh.internal.mutantmell.net saint-arkh.internal

# --- VLAN 10 (network devices) ---
10.97.10.12 arseille.internal.mutantmell.net arseille.internal
10.97.10.20 merkabah.internal.mutantmell.net merkabah.internal
10.97.10.21 derfflinger.internal.mutantmell.net derfflinger.internal
10.97.10.22 pantagruel.internal.mutantmell.net pantagruel.internal
10.97.10.23 bobcat.internal.mutantmell.net bobcat.internal
10.97.10.24 lusitania.internal.mutantmell.net lusitania.internal

# --- VLAN 31 (adu) ---
10.97.31.20 glorious.internal.mutantmell.net glorious.internal

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

### ~~Blocker 3: erebonia switch (ZyXEL GS1900-10HP)~~ — RESOLVED

ZyXEL switch has been configured for VLAN 11 on erebonia's port.

---

## Phase 1: Deploy calvard (nixos-anywhere) — COMPLETE

Calvard has been deployed via nixos-anywhere with btrfs (not ZFS as originally
planned). All microVM guests (basel, creil, langport, messeldam, oracion, tharbad)
and the Incus container (edith) are running. Key differences from the original plan:

- Filesystem changed from ZFS to btrfs with LUKS encryption (keyfile unlock via ESP)
- Microvm hypervisor is cloud-hypervisor (not QEMU) with virtiofs shares
- Guest data lives under `/persist/guests/` (btrfs subvolume with impermanence)
- Remiferia's microvm guests were moved back to QEMU (cloud-hypervisor had issues on remiferia)

---

## Phase 2: Update remiferia (in-place nixos-rebuild) — COMPLETE

Remiferia was updated in-place via `nixos-rebuild`. ZFS data pools preserved.
Network migrated from VLAN 10 untagged to VLAN 11 tagged. MicroVM guests
(ardent, monrain) running. NFS exports and Samba operational.

---

## Phase 3: Deploy erebonia (nixos-anywhere) — COMPLETE

Erebonia deployed via nixos-anywhere (2026-03-18) with btrfs + LUKS encryption,
matching calvard's profile. Switched from ZFS to btrfs (ZFS had issues with
cloud-hypervisor). MicroVM guest (saint-arkh) and Incus guest (trista) both
running with no failed units. NFS `/mnt/data` mount configured with automount.

---

## Phase 4: Post-migration cleanup

After all three hosts are deployed and stable:

1. ~~**Remove legacy 10.0.x.x addresses**~~ — **DONE** (2026-03-15).
   Removed `legacyIpv4Prefix`, `ipv4Legacy`/`cidr4Legacy`/`subnet4Legacy`/`gateway4Legacy`
   from network registry. Removed dual addresses from all host configs, firewall rules,
   NFS exports, DNS records, chrony allows, step-ca policy. Renamed `mkDualEgressRules`
   → `mkEgressRules`. Moved mesh hosts (merkabah, derfflinger, pantagruel, bobcat,
   lusitania, azoth) from `mkMeshHost` into proper zone-based addressing. Updated OpenWrt
   data to use 10.97 as primary gateway. Removed 10.0 and 10.1 prefixes from OpenWrt
   `mkAddresses`/`mkGateway`. Updated tests (network-helpers, openwrt-config pass).

2. **Remove VLAN 10 from switches** — No longer needed

3. **Remove backward-compat aliases:**
   - JOTUNHEIMR netbios alias on remiferia
   - yggdrasil.local / jotunheimr.local DNS aliases

4. **Decommission old erebonia guests** — Already complete. The old erebonia guests
   (roer, legram, ymir, ordis, heimdallr) have been replaced by calvard guests
   (messeldam, basel, tharbad, langport, oracion) and removed from the network registry.

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

| Host      | IP          | VLAN | Status       |
| --------- | ----------- | ---- | ------------ |
| calvard   | 10.97.11.30 | 11   | **Deployed** |
| remiferia | 10.97.11.20 | 11   | **Deployed** |
| erebonia  | 10.97.11.31 | 11   | **Deployed** |
| phantasma | 10.97.11.2  | 11   | **Deployed** |

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
