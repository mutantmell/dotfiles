# MicroVM Inventory

Comprehensive inventory of all microvms — existing and planned — derived from the
implementation plans in `llm-notes/`.

## Summary Table

| Name               | Status                        | Host      | Zone (VLAN) | IP Address                 | Purpose                                    | Hypervisor                           |
| ------------------ | ----------------------------- | --------- | ----------- | -------------------------- | ------------------------------------------ | ------------------------------------ |
| phantasma          | Existing                      | thebeyond | vINFRA (10) | 10.0.10.2                  | DNS, DHCP, Adguard Home, oauth2-proxy      | cloud-hypervisor                     |
| ardent             | Existing                      | remiferia | vDMZ (100)  | 10.97.100.31 / 10.0.100.31 | Attic binary cache                         | microvm (QEMU)                       |
| monrain            | Config ready (deploy pending) | remiferia | vDMZ (100)  | 10.97.100.32 / 10.0.100.32 | cgit bare repository hosting               | microvm (QEMU)                       |
| creil              | Deployed                      | calvard   | vDMZ (100)  | 10.97.100.53 / 10.0.100.53 | Forgejo git hosting                        | cloud-hypervisor                     |
| saint-arkh         | Config ready (deploy pending) | erebonia  | vDMZ (100)  | 10.97.100.61 / 10.0.100.61 | Forgejo Actions CI/CD runners              | microvm (QEMU)                       |
| messeldam          | Deployed                      | calvard   | vINFRA (11) | 10.97.11.6 / 10.0.11.6     | Keycloak OIDC identity provider            | cloud-hypervisor                     |
| basel              | Deployed                      | calvard   | vINFRA (11) | 10.97.11.7 / 10.0.11.7     | PKI / certificate authority                | cloud-hypervisor                     |
| langport           | Deployed                      | calvard   | vDMZ (100)  | 10.97.100.41 / 10.0.100.41 | Reverse proxy, oauth2-proxy, wg-ba gateway | cloud-hypervisor                     |
| oracion            | Deployed                      | calvard   | vDMZ (100)  | 10.97.100.52 / 10.0.100.52 | Jellyfin media server                      | cloud-hypervisor                     |
| tharbad            | Deployed                      | calvard   | vMGMT (20)  | 10.97.20.41 / 10.0.20.41   | Prometheus+Loki+Alertmanager+ntfy          | cloud-hypervisor                     |
| edith              | Deployed                      | calvard   | vMGMT (20)  | 10.97.20.42 / 10.0.20.42   | Dev environment / task runner (primary)    | Incus container                      |
| trista             | Existing                      | erebonia  | vDMZ (100)  | 10.0.100.x                 | Dev environment / task runner (backup)     | Incus VM                             |
| altair             | Planned                       | calvard   | vDMZ (100)  | TBD                        | Tailscale control plane (Headscale)        | microvm (QEMU)                       |
| longlai            | Planned                       | calvard   | vDMZ (100)  | TBD                        | Tailscale subnet router                    | microvm (QEMU)                       |
| Game servers (TBD) | Planned                       | calvard   | vDMZ (100)  | TBD                        | Game hosting (Minecraft, Factorio, etc.)   | TBD                                  |

---

## Existing MicroVMs

### phantasma — DNS & Ad Blocking

| Property           | Value                                              |
| ------------------ | -------------------------------------------------- |
| Host               | thebeyond (router)                                 |
| Zone               | vINFRA (VLAN 10, migrating to VLAN 11)             |
| IP                 | 10.0.10.2 (will become 10.0.11.2 after VLAN split) |
| Hypervisor         | cloud-hypervisor                                   |
| vCPU / RAM         | 1 / 512MB                                          |
| Persistent storage | 10MB                                               |
| MAC                | 5E:10:AD:01:00:02                                  |
| Config             | `hosts/thebeyond/guests/phantasma/`                |

**Services:** Unbound (split-horizon DNS), Adguard Home (DNS filtering), oauth2-proxy
(internal service auth), nginx (TLS termination).

**Planned changes:** Migrates from VLAN 10 to VLAN 11 (vINFRA) during the Secure MGMT
VLAN Split (Step 2). DNS zones migrate from `.local` to `.internal.mutantmell.net` /
`.internal` during Step 4.

---

### ardent — Binary Cache

| Property           | Value                                                          |
| ------------------ | -------------------------------------------------------------- |
| Host               | remiferia                                                      |
| Zone               | vDMZ (VLAN 100)                                                |
| IP                 | 10.97.100.31 / 10.0.100.31                                     |
| Hypervisor         | microvm (QEMU)                                                 |
| vCPU / RAM         | 2 / 2049MB                                                      |
| Persistent storage | 25GB                                                           |
| MAC                | 5E:A5:4D:A3:A0:1A                                              |
| Config             | `hosts/remiferia/guests/ardent/`                               |

**Services:** Attic (Nix binary cache server). Forgejo split to creil (calvard), cgit
split to monrain (remiferia), CI/CD runners split to saint-arkh (erebonia).

**Planned changes:** Hypervisor migration to cloud-hypervisor was attempted but reverted
due to issues on remiferia. ardent remains on QEMU with 9p shares.

**Rationale for keeping Attic on remiferia:** Binary cache blobs are large; co-locating
Attic with the NAS avoids unnecessary cross-host transfers.

---

### monrain — cgit Repository Browser

| Property           | Value                             |
| ------------------ | --------------------------------- |
| Host               | remiferia                         |
| Zone               | vDMZ (VLAN 100)                   |
| IP                 | 10.97.100.32 / 10.0.100.32        |
| Hypervisor         | microvm (QEMU)                    |
| vCPU / RAM         | 1 / 512MB                         |
| Persistent storage | 25GB (git repos in /var/lib/git)  |
| MAC                | 5E:A5:4D:A3:A0:20                 |
| Config             | `hosts/remiferia/guests/monrain/` |

**Services:** cgit (read-only git web frontend), nginx (TLS termination for
monrain.internal), sshd (git-shell access for pushing bare repos).

**DNS names:**

- Internal: `monrain.internal.mutantmell.net` / `monrain.internal`

**Notes:** Split out from ardent. Bare git repos live in `/var/lib/git`. Authorized push
keys include `deploy`, `home`, `remiferia`, `erebonia`, `calvard`.

---

### denai — Development Workstation (slated for removal)

| Property           | Value                                   |
| ------------------ | --------------------------------------- |
| Host               | remiferia                               |
| Zone               | vMGMT (VLAN 20)                         |
| IP                 | 10.0.20.40                              |
| Hypervisor         | microvm (QEMU)                          |
| vCPU / RAM         | 2 / 3072MB                              |
| Persistent storage | 175MB (100MB root + 75MB store overlay) |
| MAC                | 5E:A4:B9:D2:F8:03                       |
| Config             | `hosts/remiferia/guests/denai/`         |

**Services:** Build/development environment with aarch64 cross-compilation support, SMB
mounts to remiferia NAS.

**Status:** Slated for removal, independently of the calvard migration. Its role is
replaced by edith (Incus container on calvard, primary) and trista (Incus VM on
erebonia, backup).

---

### oracion — Media Server

_Renamed from `heimdallr` (erebonia → calvard migration)._

| Property           | Value                           |
| ------------------ | ------------------------------- |
| Host               | calvard                         |
| Zone               | vDMZ (VLAN 100)                 |
| IP                 | 10.97.100.52 / 10.0.100.52      |
| Hypervisor         | microvm (QEMU)                  |
| vCPU / RAM         | 2 / 3096MB                      |
| Persistent storage | 10MB                            |
| MAC                | 5E:64:00:34:00:01               |
| Config             | `hosts/calvard/guests/oracion/` |

**Services:** Jellyfin (media streaming with Intel VAAPI hardware transcoding).

**Planned changes:** Will get native OIDC integration with Keycloak (security
recommendation R2 — survives oauth2-proxy bypass). Egress filtering added in Step 2.

---

### langport — Reverse Proxy & Web Gateway

_Renamed from `ordis` (erebonia → calvard migration)._

| Property           | Value                                |
| ------------------ | ------------------------------------ |
| Host               | calvard                              |
| Zone               | vDMZ (VLAN 100)                      |
| IP                 | 10.97.100.41 / 10.0.100.41           |
| Hypervisor         | microvm (QEMU)                       |
| vCPU / RAM         | 2 / 1024MB                           |
| Persistent storage | 29MB (25MB root + 4MB store overlay) |
| MAC                | 5E:64:00:29:00:01                    |
| Config             | `hosts/calvard/guests/langport/`     |

**Services:** nginx (reverse proxy for external-facing services), oauth2-proxy (web
traffic authentication), WireGuard (wg-ba gateway from cloud host).

**Planned changes:**

- New vhosts: `auth.mutantmell.net` (Keycloak proxy), `vpn.mutantmell.net` (Headscale
  proxy) — Steps 4, 7
- SSH daemon removed (replaced by dedicated bastion) — Step 4, Phase 3
- Rate limiting on `/auth/` and `/oauth2/` paths — Step 4, Phase 3
- Egress filtering — Step 2, Phase 4.4

---

### tharbad — System Monitoring

_Renamed from `ymir` (erebonia → calvard migration)._

| Property           | Value                           |
| ------------------ | ------------------------------- |
| Host               | calvard                         |
| Zone               | vMGMT (VLAN 20)                 |
| IP                 | 10.97.20.41 / 10.0.20.41        |
| Hypervisor         | microvm (QEMU)                  |
| vCPU / RAM         | 2 / 2049MB                      |
| Persistent storage | 30MB                            |
| MAC                | 5E:A2:E4:CB:05:DA               |
| Config             | `hosts/calvard/guests/tharbad/` |

**Services:** Prometheus (metrics collection), Loki (log aggregation), Alertmanager
(alert routing), ntfy (push notifications).

**Planned changes:** None for the monitoring stack. Loki stays co-located with
Prometheus+Alertmanager+ntfy — see `plans/vm-guest-rebalance.md` Phase 6 for rationale.

---

### messeldam — Centralized Identity Provider

_Renamed from `roer` (erebonia → calvard migration)._

| Property           | Value                                |
| ------------------ | ------------------------------------ |
| Host               | calvard                              |
| Zone               | vINFRA (VLAN 11)                     |
| IP                 | 10.97.11.6 / 10.0.11.6               |
| Hypervisor         | microvm (QEMU)                       |
| vCPU / RAM         | 2 / 2049MB                           |
| Persistent storage | ~100GB (PostgreSQL database)         |
| Deployed by        | Step 0 — calvard migration (Phase 2) |
| Plan               | `plans/vm-guest-rebalance.md`        |
| Config             | `hosts/calvard/guests/messeldam/`    |

**Services:** Keycloak (OIDC identity provider), PostgreSQL (user database), nginx
(local reverse proxy, hostname-admin restriction).

**DNS names:**

- External: `auth.mutantmell.net` (proxied through langport for external users)
- Internal: `messeldam.internal.mutantmell.net` / `messeldam.internal`
- Admin console: internal hostname only (security hardening R1)

**Notes:** Replaced Keycloak from the decommissioned gridr VM. Dedicated microvm isolates
the JVM + PostgreSQL attack surface from CA key material. Hosts the `homelab` realm
(replacing current `external` realm). All oauth2-proxy instances, step-ca, headscale,
and services with native OIDC authenticate against this. Hosted on calvard with a vINFRA
(VLAN 11) bridge interface alongside its vDMZ and vMGMT bridges.

---

### basel — PKI / Certificate Authority

_Renamed from `legram` (erebonia → calvard migration)._

| Property           | Value                                                        |
| ------------------ | ------------------------------------------------------------ |
| Host               | calvard                                                      |
| Zone               | vINFRA (VLAN 11)                                             |
| IP                 | 10.97.11.7 / 10.0.11.7                                       |
| Hypervisor         | microvm (QEMU)                                               |
| vCPU / RAM         | 1 / 512MB                                                    |
| Persistent storage | Small (badger DB + CA root keys)                             |
| Deployed by        | Step 0 — calvard migration (Phase 2)                         |
| Plans              | `plans/vm-guest-rebalance.md`, `keycloak-oauth-oidc-plan.md` |
| Config             | `hosts/calvard/guests/basel/`                                |

**Services:** step-ca (ACME CA + SSH CA with OIDC provisioner), nginx (TLS termination
for ACME endpoint on :443).

**DNS names:**

- Internal: `basel.internal.mutantmell.net` / `basel.internal`
- ACME endpoint: `https://basel.internal.mutantmell.net/acme/acme/directory`

**Notes:** Replaced step-ca from the decommissioned gridr VM. Separate from Keycloak
(messeldam) for CA key material isolation — compromise of one doesn't expose the other. OIDC
provisioner validates tokens against messeldam for SSH certificate issuance. Critical data
(CA root keys) must be backed up. Co-located on calvard with messeldam for intra-zone
communication.

---

### trista — Dev Environment / Task Runner (backup)

| Property           | Value           |
| ------------------ | --------------- |
| Host               | erebonia        |
| Zone               | vDMZ (VLAN 100) |
| IP                 | 10.0.100.x      |
| Hypervisor         | Incus VM        |
| vCPU / RAM         | TBD             |
| Persistent storage | TBD             |

**Services:** Development environment and task runner.

**DNS names:**

- Internal: `trista.internal.mutantmell.net` / `trista.internal`

**Notes:** Incus VM on erebonia. Trista is an Erebonian city (correct host). Serves as
backup dev env; primary dev env is edith on calvard. Does **not** use Microvm.nix.

---

### edith — Dev Environment / Task Runner (primary)

| Property           | Value                             |
| ------------------ | --------------------------------- |
| Host               | calvard                           |
| Zone               | vMGMT (20)                        |
| IP                 | TBD                               |
| Hypervisor         | Incus container                   |
| vCPU / RAM         | TBD                               |
| Persistent storage | TBD                               |
| IP                 | 10.97.20.42 / 10.0.20.42          |
| Config             | `hosts/calvard/containers/edith/` |

**Services:** Development environment and task runner.

**DNS names:**

- Internal: `edith.internal.mutantmell.net` / `edith.internal`

**Notes:** Incus container on calvard. Primary dev env replacing denai. Does **not** use
Microvm.nix — managed via Incus declarative config.

---

## Planned MicroVMs

### altair — Tailscale Control Plane

_Assigned name: altair._

| Property           | Value                                            |
| ------------------ | ------------------------------------------------ |
| Host               | calvard                                          |
| Zone               | vDMZ (VLAN 100)                                  |
| IP                 | Next available vDMZ address                      |
| Hypervisor         | microvm (QEMU)                                   |
| vCPU / RAM         | 1 / 512MB                                        |
| Persistent storage | Small (SQLite DB, noise private key, ACL policy) |
| Introduced by      | Step 7 — Headscale (Phase 1)                     |
| Plan               | `headscale-integration-plan.md`                  |

**Services:** Headscale (open-source Tailscale control server with embedded DERP relay

- STUN listener), nginx (TLS termination).

**DNS names:**

- External: `vpn.mutantmell.net` (proxied through langport)
- Internal: TBD (pending hostname assignment)

**Cross-zone firewall:** Headscale VM (vDMZ) -> messeldam (vINFRA) on TCP 443 for OIDC
validation.

**Notes:** On vDMZ because embedded DERP/STUN must be reachable from external users.
OIDC integration with messeldam (Keycloak) for friend authentication. Loss of SQLite DB
means all nodes must re-register.

---

### longlai — Tailscale Subnet Router

_Assigned name: longlai._

| Property           | Value                           |
| ------------------ | ------------------------------- |
| Host               | calvard                         |
| Zone               | vDMZ (VLAN 100)                 |
| IP                 | TBD                             |
| Hypervisor         | microvm (QEMU)                  |
| vCPU / RAM         | 1 / 256MB                       |
| Persistent storage | Minimal (Tailscale state)       |
| Introduced by      | Step 7 — Headscale (Phase 2)    |
| Plan               | `headscale-integration-plan.md` |

**Services:** Tailscale daemon (subnet router mode, advertises 10.0.100.0/24).

**Notes:** Bridges the Tailscale overlay network into vDMZ. Friends' game traffic
arrives through WireGuard tunnels and gets forwarded to game servers. Headscale ACLs
restrict which IPs/ports friends can actually reach. Lightweight — only runs the
Tailscale daemon.

---

### Game Servers — Friend-Accessible Game Hosting

_Names, count, and specifics: TBD. Will use Calvard city names._

| Property           | Value                                      |
| ------------------ | ------------------------------------------ |
| Host               | calvard                                    |
| Zone               | vDMZ (VLAN 100)                            |
| IP                 | 10.0.100.70+ (tentative, per ACL examples) |
| Hypervisor         | TBD (microvm or container)                 |
| vCPU / RAM         | Per game requirements                      |
| Persistent storage | Per game requirements                      |
| Introduced by      | Step 7 — Headscale (Phase 6)               |
| Plan               | `headscale-integration-plan.md`            |

**Notes:** Specific games are deferred — the architecture supports any game server.
Examples from the plan: Minecraft (TCP 25565), Factorio (UDP 34197), Valheim (UDP
2456-2458), Terraria (TCP 7777), Satisfactory (UDP 7777/15000/15777). Friends access
these through the Tailscale overlay via the subnet router. ACLs on headscale control
which ports/IPs each friend group can reach.

---

## Open Questions

1. ~~**Calvard names for planned VMs.**~~ Resolved — altair (Headscale), longlai (subnet router), creil (Forgejo). nemeth reserved but unallocated.

2. **Game server specifics.** Game selection, hosting model (microvm vs container), and
   resource allocation are all deferred.

3. **calvard capacity.** calvard will host the bulk of guests: messeldam, basel, langport,
   oracion, tharbad, edith, plus the planned Headscale, subnet router, SSH bastion,
   and game servers. Ensure calvard has sufficient RAM, CPU, and storage — particularly
   for messeldam's ~100GB PostgreSQL requirement.

4. ~~**vINFRA bridge on calvard.**~~ Resolved — br11 bridge added to calvard/microvm.nix.

5. **Incus VM vs container on calvard.** The SSH bastion requires an Incus VM (not just
   a container). calvard will need to support both Incus container (edith) and Incus
   VM (SSH bastion) workloads.

6. **denai removal.** denai is slated for removal from remiferia but can be decommissioned
   independently of the calvard migration.

---

## Host Capacity Overview

| Host      | Role            | Current Guests                                             | Planned Guests                       | Notes                                                    |
| --------- | --------------- | ---------------------------------------------------------- | ------------------------------------ | -------------------------------------------------------- |
| thebeyond | Router          | phantasma                                                  | —                                    | cloud-hypervisor; resource-constrained                   |
| remiferia | NAS + VM host   | ardent, monrain, denai\*                                   | —                                    | \*denai slated for removal independently                 |
| erebonia  | VM host + Incus | trista                                                     | saint-arkh (Forgejo Actions runners) | Async CI/CD workloads; Forgejo service itself on calvard |
| calvard   | VM host + Incus | messeldam, basel, langport, oracion, tharbad, creil, edith | altair, longlai, game servers        | Primary VM host; cloud-hypervisor; all guests deployed   |

---

## Implementation Timeline

MicroVMs are introduced across the 7-step implementation roadmap. The calvard migration
is a prerequisite that must complete before new calvard guests can be added.

See `plans/vm-guest-rebalance.md` for the detailed calvard migration plan.

| Step                      | MicroVM Changes                                                                                                                                                                                |
| ------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| 0. calvard migration      | **COMPLETE.** messeldam, basel, langport, oracion, tharbad, creil deployed on calvard (cloud-hypervisor). edith deployed (Incus container). denai still on remiferia (slated for removal).      |
| 1. Zone Refactor          | None (pure firewall refactor)                                                                                                                                                                  |
| 2. Secure MGMT VLAN Split | phantasma migrates from VLAN 10 to VLAN 11; egress filtering added to all vDMZ microvms                                                                                                        |
| 3. Network Data Registry  | None (data migration)                                                                                                                                                                          |
| 4. Keycloak OIDC          | messeldam (Keycloak) and basel (step-ca) already deployed on calvard. **Planned:** SSH bastion (Calvard name TBD, Incus VM on calvard). **Decommissioned:** gridr                              |
| 5. IP Migration           | All microvms get dual addresses (10.0.x.x + 10.97.x.x)                                                                                                                                         |
| 6. SSH Certificates       | None (configuration changes to existing hosts)                                                                                                                                                 |
| 7. Headscale              | **Planned:** Headscale VM (Calvard name TBD), subnet router (Calvard name TBD), game servers (Calvard names TBD) — all on calvard                                                              |
