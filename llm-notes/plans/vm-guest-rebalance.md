# VM Guest Rebalance Plan

## Goal

Move the user-facing / real-time microVM guests currently on erebonia to calvard,
assigning them new Calvard city names. Erebonia is repurposed as the host for
background/async services (CI/CD Actions runners, log aggregation) that do not have
hard real-time or client-driven latency requirements. Add Incus-based dev
environments on calvard (primary) and retain the existing one on erebonia (backup).
Retire denai from remiferia independently.

The ardent guest on remiferia is split into three: Forgejo git hosting moves to a new
calvard guest (user-facing HTTP, close to langport and messeldam), CI/CD Actions runners
move to saint-arkh on erebonia (async, CPU-spiky), and ardent itself is narrowed to
Attic binary cache only.

### Host placement philosophy

| Host      | Character              | Services                                                      |
| --------- | ---------------------- | ------------------------------------------------------------- |
| calvard   | Real-time, user-facing | Reverse proxy, OIDC, media, monitoring, Forgejo git, dev env  |
| erebonia  | Background / async     | CI/CD Actions runners, log aggregation, dev env backup        |
| remiferia | NAS-adjacent           | Attic binary cache (large blobs benefit from NAS co-location) |
| thebeyond | Router                 | DNS, DHCP only                                                |

---

## Current State (post-calvard deployment)

The calvard migration (Phases 1–5) is complete. The old erebonia guests
(roer, legram, ordis, heimdallr, ymir) have been replaced and removed
from the network registry.

| Guest     | Host      | Name origin     | Hypervisor       | Service                              | Status                |
| --------- | --------- | --------------- | ---------------- | ------------------------------------ | --------------------- |
| messeldam | calvard   | Calvard city    | cloud-hypervisor | Keycloak OIDC                        | Deployed              |
| basel     | calvard   | Calvard city    | cloud-hypervisor | step-ca PKI / CA                     | Deployed              |
| langport  | calvard   | Calvard city    | cloud-hypervisor | Reverse proxy                        | Deployed              |
| oracion   | calvard   | Calvard city    | cloud-hypervisor | Jellyfin media                       | Deployed              |
| tharbad   | calvard   | Calvard city    | cloud-hypervisor | Prometheus+Loki+Alertmanager+ntfy    | Deployed              |
| creil     | calvard   | Calvard city    | cloud-hypervisor | Forgejo git hosting                  | Deployed              |
| edith     | calvard   | Calvard city    | Incus container  | Dev env (primary)                    | Deployed              |
| trista    | erebonia  | Erebonian city  | Incus VM         | Dev env (backup)                     | Existing              |
| ardent    | remiferia | Remiferian city | microvm (QEMU)   | Attic binary cache                   | Existing              |
| monrain   | remiferia | Remiferian city | microvm (QEMU)   | cgit bare repository hosting         | Config ready          |
| denai     | remiferia | Remiferian city | microvm (QEMU)   | Dev workstation (slated for removal) | Existing              |

---

## Target State

| New Name   | Old Name       | Host      | Hypervisor       | Service                              |
| ---------- | -------------- | --------- | ---------------- | ------------------------------------ |
| messeldam  | roer           | calvard   | cloud-hypervisor | Keycloak OIDC                        |
| basel      | legram         | calvard   | cloud-hypervisor | step-ca PKI / CA                     |
| langport   | ordis          | calvard   | cloud-hypervisor | Reverse proxy                        |
| oracion    | heimdallr      | calvard   | cloud-hypervisor | Jellyfin media                       |
| tharbad    | ymir           | calvard   | cloud-hypervisor | Monitoring                           |
| edith      | (new)          | calvard   | Incus container  | Dev env (primary)                    |
| creil      | ardent (split) | calvard   | cloud-hypervisor | Forgejo git hosting                  |
| trista     | trista         | erebonia  | Incus VM         | Dev env (backup)                     |
| saint-arkh | ardent (split) | erebonia  | microvm (QEMU)   | Forgejo Actions CI/CD runners        |
| ardent     | ardent (split) | remiferia | microvm (QEMU)   | Attic binary cache only              |
| denai      | denai          | remiferia | microvm (QEMU)   | Dev workstation (slated for removal) |

### Naming rationale

Guest names serve as a mnemonic for which host they run on:

- **Calvard city names** — calvard guests; messeldam, basel, langport, oracion, tharbad,
  edith, creil are assigned; altair (Headscale) and longlai (subnet router) are
  reserved for future phases; nemeth is unallocated
- **Erebonian city names** — erebonia guests; `trista` already follows this convention;
  `saint-arkh` is assigned to the CI/CD runner guest
- **Remiferian city names** — remiferia guests; ardent keeps its name, narrowed to Attic only

### Incus requirement

`edith` (Incus container) and the future SSH bastion (Incus VM) on calvard must
**not** use `Microvm.nix`. They are managed via Incus declarative config, analogous to
how `trista` is managed on erebonia today.

---

## Prerequisites

- calvard must have bridge interfaces for all required VLANs:
  - vDMZ (VLAN 100) — for langport, oracion, and future DMZ guests
  - vMGMT (VLAN 20) — for tharbad, edith
  - vINFRA (VLAN 11) — for messeldam and basel (new requirement; erebonia already has this)
- calvard must have Incus configured (container + VM support) for edith and the
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
   references in phantasma's nginx, roer→messeldam references in legram's step-ca config)
5. **MAC address / tap interface**: the tap interface ID and MAC change (e.g. `vm-11-roer`
   → `vm-11-messeldam`); update any DHCP static reservations and MAC-based firewall rules
6. **Persistent volume paths**: volumes live at `/persist/guests/<old-name>/images/` on
   the source host; create equivalent paths on the target host before deploying
7. **sops re-encryption**: each guest's secrets are encrypted to the guest's own SSH host
   key. After first boot on the new host, retrieve the new SSH public key, convert to age
   (`ssh-to-age`), and re-encrypt secrets with `sops updatekeys` or by re-running the
   encrypt command recorded at the top of each `secrets.yaml`
8. Deploy the new guest on the target host and verify services are healthy
9. Update phantasma's DNS to point the service's `.internal` name at the new IP
10. Decommission the old guest (remove config, remove from network registry)

### Phase 1 — calvard infrastructure — COMPLETE

- [x] Add vINFRA (VLAN 11) bridge to calvard's network config
- [x] Verify vDMZ and vMGMT bridges exist and are functional
- [x] Add calvard's `microvm.nix` guest declarations (tap interfaces,
      volume paths under `/persist/guests/`)
- [x] Configure Incus on calvard (enable container + VM support)
- [x] Verify Incus networking bridges match VLAN assignments

### Phase 2 — Migrate infrastructure tier (vINFRA) — COMPLETE

- [x] Allocate IPs for messeldam and basel in network registry
- [x] Create `hosts/calvard/guests/messeldam/` — Keycloak OIDC (cloud-hypervisor)
- [x] Create `hosts/calvard/guests/basel/` — step-ca PKI / CA (cloud-hypervisor)
- [x] Deploy messeldam and basel on calvard
- [x] Old erebonia guests (roer, legram) removed from network registry

### Phase 3 — Migrate DMZ tier (vDMZ) — COMPLETE

- [x] Create `hosts/calvard/guests/langport/` — reverse proxy (cloud-hypervisor)
- [x] Create `hosts/calvard/guests/oracion/` — Jellyfin media (cloud-hypervisor)
- [x] Deploy langport and oracion on calvard
- [x] Old erebonia guests (ordis, heimdallr) removed from network registry

### Phase 4 — Migrate management tier (vMGMT) — COMPLETE

- [x] Create `hosts/calvard/guests/tharbad/` — monitoring (cloud-hypervisor)
- [x] Deploy tharbad on calvard
- [x] Old erebonia guest (ymir) removed from network registry

### Phase 5 — Add edith (primary dev env, Incus container) — COMPLETE

- [x] Create `hosts/calvard/incus/edith/` (Incus declarative config, no Microvm.nix)
- [x] Deploy edith on calvard

### Phase 6 — Split ardent into three guests

ardent currently runs Attic (binary cache) and Forgejo (git hosting + Actions CI/CD
runners). These are split into three independent guests with separate lifecycles,
resource limits, and firewall egress rules:

| Guest            | Host      | Services                      | Rationale                                          |
| ---------------- | --------- | ----------------------------- | -------------------------------------------------- |
| ardent           | remiferia | Attic binary cache only       | Large blobs benefit from NAS co-location           |
| TBD Calvard name | calvard   | Forgejo git hosting + web UI  | User-facing HTTP; close to langport and messeldam  |
| saint-arkh       | erebonia  | Forgejo Actions CI/CD runners | Async, CPU-spiky; isolated from real-time services |

Runners communicate with the Forgejo API over the network using a registration token —
the separation is already native to Forgejo Actions architecture.

#### monrain — cgit service guest on remiferia

cgit moved to its own microVM on remiferia so that the internal nginx reverse proxy on
ardent is no longer needed. `monrain.internal` resolves directly to monrain's IP;
monrain runs nginx+ACME and terminates TLS itself.

- [x] Add `monrain = 32` to dmz hosts in network registry
- [x] Create `hosts/remiferia/guests/monrain/` — cgit, nginx/ACME for monrain.internal
- [x] Update phantasma DNS: `monrain.internal`
- [x] Remove `git.internal` split-horizon entries from phantasma DNS
- [x] Update docs/hostnames.md: monrain allocated
- [ ] Deploy and verify cgit accessible at monrain.internal
- [ ] Migrate git repos from ardent (`rsync /var/lib/git`)

#### ardent — narrow to Attic only

Cloud-hypervisor migration was attempted but reverted due to issues on remiferia.
ardent remains on QEMU with 9p shares.

- [ ] Remove Forgejo + runner config from `hosts/remiferia/guests/ardent/`
- [ ] Keep ardent running Attic only (large binary blobs benefit from NAS co-location)
- [ ] Update phantasma DNS: remove `ardent.internal` Forgejo entry

#### creil — Forgejo service guest on calvard

- [x] Assign Calvard city name (creil); added to `docs/hostnames.md`
- [x] Allocate IP on vDMZ in network registry (10.97.100.53)
- [x] Create `hosts/calvard/guests/creil/` — Forgejo (sqlite3), nginx/ACME for creil.internal
- [x] Update phantasma DNS: `creil.internal`
- [ ] Deploy and verify Forgejo accessible
- [ ] Migrate Forgejo data from ardent (repo data copy via `rsync /var/lib/forgejo`)

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

| Plan                                    | Stale Assignment                                | Correct Host |
| --------------------------------------- | ----------------------------------------------- | ------------ |
| `headscale-integration-plan.md` Phase 1 | headscale control server → erebonia             | calvard      |
| `headscale-integration-plan.md` Phase 2 | fenrir (subnet router) → erebonia               | calvard      |
| `feature-roadmap-analysis.md` summary   | "All planned microvms are assigned to erebonia" | calvard      |

None of these VMs have been configured yet, so there is no migration work — the
references simply need to be updated to point at calvard. The stale text in each plan
has been amended (see those files), but if any new plan is derived from them, use
calvard as the target host.

---

## Future Calvard Guests (out of scope for this plan)

These are tracked in `microvm-inventory.md` and their respective feature plans:

| Purpose                 | Plan                                    | Name                |
| ----------------------- | --------------------------------------- | ------------------- |
| SSH jump host           | `keycloak-oauth-oidc-plan.md` Phase 3   | TBD (Calvard name)  |
| Headscale control plane | `headscale-integration-plan.md` Phase 1 | TBD (Calvard name)  |
| Tailscale subnet router | `headscale-integration-plan.md` Phase 2 | TBD (Calvard name)  |
| Game servers            | `headscale-integration-plan.md` Phase 6 | TBD (Calvard names) |

Remaining unallocated Calvard names: tharbad and edith are used above; remaining
pool from `docs/hostnames.md`: none currently listed as spare — new names will need to
be added to `docs/hostnames.md` before those guests are created.
