# VM Guest Rebalance Plan

## Goal

Move all microVM guests currently on erebonia to calvard, assigning them new Calvard
city names. Add Incus-based dev environments on calvard (primary) and retain the existing
one on erebonia (backup). Retire denai from remiferia independently.

---

## Current State

| Guest | Host | Name origin | Hypervisor | Service |
|-------|------|-------------|------------|---------|
| roer | erebonia | Erebonian city | microvm (QEMU) | Keycloak OIDC |
| legram | erebonia | Erebonian city | microvm (QEMU) | step-ca PKI / CA |
| ordis | erebonia | Erebonian city | microvm (QEMU) | Reverse proxy |
| heimdallr | erebonia | Erebonian city | microvm (QEMU) | Jellyfin media |
| ymir | erebonia | Erebonian city | microvm (QEMU) | Monitoring |
| trista | erebonia | Erebonian city | Incus VM | Dev env (backup) |
| ardent | remiferia | Remiferian city | microvm (QEMU) | Binary cache + Git |
| denai | remiferia | Remiferian city | microvm (QEMU) | Dev workstation |

calvard currently has no guests.

---

## Target State

| New Name | Old Name | Host | Hypervisor | Service |
|----------|----------|------|------------|---------|
| edith | roer | calvard | microvm (QEMU) | Keycloak OIDC |
| basel | legram | calvard | microvm (QEMU) | step-ca PKI / CA |
| langport | ordis | calvard | microvm (QEMU) | Reverse proxy |
| oracion | heimdallr | calvard | microvm (QEMU) | Jellyfin media |
| tharbad | ymir | calvard | microvm (QEMU) | Monitoring |
| messeldam | (new) | calvard | Incus container | Dev env (primary) |
| trista | trista | erebonia | Incus VM | Dev env (backup) |
| ardent | ardent | remiferia | microvm (QEMU) | Binary cache + Git |
| denai | denai | remiferia | microvm (QEMU) | Dev workstation (slated for removal) |

### Naming rationale

Guest names serve as a mnemonic for which host they run on. Calvard city names (edith,
basel, langport, oracion, tharbad, messeldam) replace the Erebonian city names of the
migrated guests. `trista` is itself an Erebonian city and correctly remains on erebonia.

### Incus requirement

`messeldam` (Incus container) and the future SSH bastion (Incus VM) on calvard must
**not** use `Microvm.nix`. They are managed via Incus declarative config, analogous to
how `trista` is managed on erebonia today.

---

## Prerequisites

- calvard must have bridge interfaces for all required VLANs:
  - vDMZ (VLAN 100) — for langport, oracion, and future DMZ guests
  - vMGMT (VLAN 20) — for tharbad, messeldam
  - vINFRA (VLAN 11) — for edith and basel (new requirement; erebonia already has this)
- calvard must have Incus configured (container + VM support) for messeldam and the
  future SSH bastion
- Network registry (`lib/common/data/network.nix`) must be updated with new hostnames
  and IP allocations for all calvard guests before services go live

---

## Migration Steps

Each microVM migration follows the same pattern:

1. Allocate a new IP for the guest on calvard in the network registry
2. Create `hosts/calvard/guests/<new-name>/` by copying from `hosts/erebonia/guests/<old-name>/`
3. Update all internal references (hostnames, DNS, sops secret paths) in the new config
4. Update any configs on other hosts that reference the old hostname (e.g. ordis→langport
   references in phantasma's nginx, roer→edith references in legram's step-ca config)
5. Deploy the new guest on calvard and verify services are healthy
6. Update phantasma's DNS to point the service's `.internal` name at the new IP
7. Decommission the old guest on erebonia (remove config, remove from network registry)

### Phase 1 — calvard infrastructure

- [ ] Add vINFRA (VLAN 11) bridge to calvard's network config
- [ ] Verify vDMZ and vMGMT bridges exist and are functional
- [ ] Configure Incus on calvard (enable container + VM support)
- [ ] Verify Incus networking bridges match VLAN assignments

### Phase 2 — Migrate infrastructure tier (vINFRA)

Migrate edith and basel first; other guests depend on them for OIDC and certificates.

- [ ] Allocate IPs for edith and basel in network registry
- [ ] Create `hosts/calvard/guests/edith/` from erebonia/roer; update hostname refs
- [ ] Create `hosts/calvard/guests/basel/` from erebonia/legram; update hostname refs
  - Update step-ca OIDC provisioner to point at edith (was roer)
  - Update ACME endpoint DNS record: `basel.internal` (was `legram.internal`)
- [ ] Deploy edith and basel on calvard; verify Keycloak and step-ca healthy
- [ ] Update phantasma DNS: `edith.internal`, `basel.internal`
- [ ] Update all oauth2-proxy instances to authenticate against edith
- [ ] Decommission roer and legram on erebonia

### Phase 3 — Migrate DMZ tier (vDMZ)

- [ ] Allocate IPs for langport and oracion in network registry
- [ ] Create `hosts/calvard/guests/langport/` from erebonia/ordis; update hostname refs
  - Update nginx vhost for `auth.mutantmell.net` proxy target (edith, not roer)
  - Update WireGuard config if peer addresses change
- [ ] Create `hosts/calvard/guests/oracion/` from erebonia/heimdallr; update hostname refs
- [ ] Deploy langport and oracion on calvard; verify nginx and Jellyfin healthy
- [ ] Update phantasma DNS: `langport.internal`, `oracion.internal`
- [ ] Update external DNS / wg-ba if langport's IP changes
- [ ] Decommission ordis and heimdallr on erebonia

### Phase 4 — Migrate management tier (vMGMT)

- [ ] Allocate IP for tharbad in network registry
- [ ] Create `hosts/calvard/guests/tharbad/` from erebonia/ymir; update hostname refs
- [ ] Deploy tharbad on calvard; verify Monit healthy
- [ ] Update phantasma DNS: `tharbad.internal`
- [ ] Decommission ymir on erebonia

### Phase 5 — Add messeldam (primary dev env, Incus container)

- [ ] Allocate IP for messeldam in network registry
- [ ] Create `hosts/calvard/containers/messeldam/` (Incus declarative config, no Microvm.nix)
- [ ] Deploy messeldam on calvard; verify dev environment functional
- [ ] Update phantasma DNS: `messeldam.internal`

### Phase 6 — Retire denai (independent, any time after Phase 5)

- [ ] Migrate any workloads or data off denai
- [ ] Remove `hosts/remiferia/guests/denai/`
- [ ] Remove denai from network registry and phantasma DNS
- [ ] Remove denai from remiferia's NixOS config

---

## Documentation Updates (each phase)

After each phase, keep these in sync:

- `docs/hostnames.md` — mark old names unallocated, new names allocated
- `llm-notes/microvm-inventory.md` — update Status, Host, IP, Config path for each guest
- `lib/common/data/network.nix` — add new entries, remove old entries

---

## Future Calvard Guests (out of scope for this plan)

These are tracked in `microvm-inventory.md` and their respective feature plans:

| Purpose | Plan | Name |
|---------|------|------|
| SSH jump host | `keycloak-oauth-oidc-plan.md` Phase 3 | TBD (Calvard name) |
| Headscale control plane | `headscale-integration-plan.md` Phase 1 | TBD (Calvard name) |
| Tailscale subnet router | `headscale-integration-plan.md` Phase 2 | TBD (Calvard name) |
| Game servers | `headscale-integration-plan.md` Phase 6 | TBD (Calvard names) |

Remaining unallocated Calvard names: tharbad and messeldam are used above; remaining
pool from `docs/hostnames.md`: none currently listed as spare — new names will need to
be added to `docs/hostnames.md` before those guests are created.
