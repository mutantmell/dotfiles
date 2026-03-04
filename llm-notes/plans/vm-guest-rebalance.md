# VM Guest Rebalance Plan

## Goal

Move the user-facing / real-time microVM guests currently on erebonia to calvard,
assigning them new Calvard city names. Erebonia is repurposed as the host for
background/async services (CI/CD Actions runners, log aggregation) that do not have
hard real-time or client-driven latency requirements. Add Incus-based dev
environments on calvard (primary) and retain the existing one on erebonia (backup).
Retire denai from remiferia independently.

The ardent guest on remiferia is split into three: Forgejo git hosting moves to a new
calvard guest (user-facing HTTP, close to langport and edith), CI/CD Actions runners
move to saint-arkh on erebonia (async, CPU-spiky), and ardent itself is narrowed to
Attic binary cache only.

### Host placement philosophy

| Host | Character | Services |
|------|-----------|---------|
| calvard | Real-time, user-facing | Reverse proxy, OIDC, media, monitoring, Forgejo git, dev env |
| erebonia | Background / async | CI/CD Actions runners, log aggregation, dev env backup |
| remiferia | NAS-adjacent | Attic binary cache (large blobs benefit from NAS co-location) |
| thebeyond | Router | DNS, DHCP only |

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
| ardent | remiferia | Remiferian city | cloud-hypervisor | Binary cache + Git |
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
| (TBD Calvard name) | ardent (split) | calvard | microvm (QEMU) | Forgejo git hosting |
| trista | trista | erebonia | Incus VM | Dev env (backup) |
| saint-arkh | ardent (split) | erebonia | microvm (QEMU) | Forgejo Actions CI/CD runners |
| ardent | ardent (split) | remiferia | cloud-hypervisor | Attic binary cache only |
| denai | denai | remiferia | microvm (QEMU) | Dev workstation (slated for removal) |

### Naming rationale

Guest names serve as a mnemonic for which host they run on:
- **Calvard city names** — calvard guests; edith, basel, langport, oracion, tharbad,
  messeldam are assigned; the new Forgejo service guest needs one more (TBD — no spare
  Calvard names currently exist in `docs/hostnames.md`; add one before Phase 6)
- **Erebonian city names** — erebonia guests; `trista` already follows this convention;
  `saint-arkh` is assigned to the CI/CD runner guest
- **Remiferian city names** — remiferia guests; ardent keeps its name, narrowed to Attic only

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
5. **MAC address / tap interface**: the tap interface ID and MAC change (e.g. `vm-11-roer`
   → `vm-11-edith`); update any DHCP static reservations and MAC-based firewall rules
6. **Persistent volume paths**: volumes live at `/persist/guests/<old-name>/images/` on
   the source host; create equivalent paths on the target host before deploying
7. **sops re-encryption**: each guest's secrets are encrypted to the guest's own SSH host
   key. After first boot on the new host, retrieve the new SSH public key, convert to age
   (`ssh-to-age`), and re-encrypt secrets with `sops updatekeys` or by re-running the
   encrypt command recorded at the top of each `secrets.yaml`
8. Deploy the new guest on the target host and verify services are healthy
9. Update phantasma's DNS to point the service's `.internal` name at the new IP
10. Decommission the old guest (remove config, remove from network registry)

### Phase 1 — calvard infrastructure

- [ ] Add vINFRA (VLAN 11) bridge to calvard's network config
- [ ] Verify vDMZ and vMGMT bridges exist and are functional
- [ ] Add calvard's `microvm.nix` guest declarations for phases 2–5 (tap interfaces,
  volume paths under `/persist/guests/`)
- [ ] Configure Incus on calvard (enable container + VM support)
- [ ] Verify Incus networking bridges match VLAN assignments

### Phase 2 — Migrate infrastructure tier (vINFRA)

Migrate edith and basel first; other guests depend on them for OIDC and certificates.

- [ ] Allocate IPs for edith and basel in network registry
- [ ] Create `hosts/calvard/guests/edith/` from erebonia/roer; update hostname refs
  - **PostgreSQL data migration**: roer's `/persist` volume is ~100GB; copy
    `/persist/guests/roer/images/persist.img` to calvard (rsync or block copy) before
    deploying, **or** perform a `pg_dump` on roer and `pg_restore` on edith after first boot
  - Re-encrypt `secrets/secrets.yaml` with edith's host key (see migration pattern step 7)
- [ ] Create `hosts/calvard/guests/basel/` from erebonia/legram; update hostname refs
  - Update step-ca OIDC provisioner to point at edith (was roer)
  - Update ACME endpoint DNS record: `basel.internal` (was `legram.internal`)
  - Re-encrypt secrets with basel's host key
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

### Phase 6 — Split ardent into three guests

ardent currently runs Attic (binary cache) and Forgejo (git hosting + Actions CI/CD
runners). These are split into three independent guests with separate lifecycles,
resource limits, and firewall egress rules:

| Guest | Host | Services | Rationale |
|-------|------|----------|-----------|
| ardent | remiferia | Attic binary cache only | Large blobs benefit from NAS co-location |
| TBD Calvard name | calvard | Forgejo git hosting + web UI | User-facing HTTP; close to langport and edith |
| saint-arkh | erebonia | Forgejo Actions CI/CD runners | Async, CPU-spiky; isolated from real-time services |

Runners communicate with the Forgejo API over the network using a registration token —
the separation is already native to Forgejo Actions architecture.

#### ardent — narrow to Attic only, migrate to cloud-hypervisor

- [ ] Remove Forgejo + runner config from `hosts/remiferia/guests/ardent/`
- [ ] Migrate ardent from QEMU to cloud-hypervisor (same pattern as phantasma on thebeyond)
- [ ] Keep ardent running Attic only (large binary blobs benefit from NAS co-location)
- [ ] Update phantasma DNS: remove `ardent.internal` Forgejo entry

#### Forgejo service guest (TBD Calvard name) — new on calvard

**Prerequisite:** add a spare Calvard city name to `docs/hostnames.md` before starting.

- [ ] Assign Calvard city name; add to `docs/hostnames.md`
- [ ] Allocate IP on vDMZ in network registry
- [ ] Create `hosts/calvard/guests/<name>/` — Forgejo, PostgreSQL
  - Move Forgejo sops secrets from ardent: `hosts/calvard/guests/<name>/sops.nix`
  - Re-encrypt secrets with the new guest's host key
- [ ] Migrate Forgejo data from ardent (pg_dump / repo data copy)
- [ ] Update langport nginx proxy for Forgejo to point at new IP
- [ ] Deploy and verify Forgejo accessible
- [ ] Update phantasma DNS: `<name>.internal`

#### CI/CD runner guest (saint-arkh) — new on erebonia

`saint-arkh` is an unallocated Erebonian city name. Add to `docs/hostnames.md`.
**Depends on** Forgejo service guest above being deployed first.

- [ ] Allocate IP for saint-arkh on vDMZ in network registry
- [ ] Create `hosts/erebonia/guests/saint-arkh/` — Forgejo Actions runner(s)
  - Move runner registration token/secrets from ardent
- [ ] Register saint-arkh runners with the Forgejo service guest
- [ ] Deploy and verify CI jobs run on saint-arkh
- [ ] Update phantasma DNS: `saint-arkh.internal`

#### Log aggregation — stays in tharbad (calvard)

Loki remains co-located with Prometheus, Alertmanager, and ntfy in tharbad on calvard.
Rationale: during an incident, log queries are interactive and time-sensitive; having Loki
on the same host as alerting avoids losing visibility if erebonia is the host under
investigation. The tight Loki → Alertmanager → ntfy pipeline also benefits from staying
on one host. `leeves` remains unallocated in `docs/hostnames.md` for future use.

### Phase 7 — Retire denai (independent, any time after Phase 5)

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

## Discrepancy: Other Plans Reference Erebonia as Microvm Host

Several plans written before calvard was designated the primary VM host still assign
future (not-yet-configured) microvms to **erebonia**:

| Plan | Stale Assignment | Correct Host |
|------|-----------------|--------------|
| `headscale-integration-plan.md` Phase 1 | headscale control server → erebonia | calvard |
| `headscale-integration-plan.md` Phase 2 | fenrir (subnet router) → erebonia | calvard |
| `feature-roadmap-analysis.md` summary | "All planned microvms are assigned to erebonia" | calvard |

None of these VMs have been configured yet, so there is no migration work — the
references simply need to be updated to point at calvard. The stale text in each plan
has been amended (see those files), but if any new plan is derived from them, use
calvard as the target host.

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
