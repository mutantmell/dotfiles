# MicroVM Inventory

Comprehensive inventory of all microvms — existing and planned — derived from the
implementation plans in `llm-notes/`.

## Summary Table

| Name | Status | Host | Zone (VLAN) | IP Address | Purpose | Hypervisor |
|------|--------|------|-------------|------------|---------|------------|
| phantasma | Existing | thebeyond | vINFRA (10) | 10.0.10.2 | DNS, DHCP, Adguard Home, oauth2-proxy | cloud-hypervisor |
| ardent | Existing | remiferia | vDMZ (100) | 10.0.100.31 | Attic binary cache, Gitea | microvm (QEMU) |
| denai | Existing | remiferia | vMGMT (20) | 10.0.20.40 | Development workstation | microvm (QEMU) |
| heimdallr | Existing | erebonia | vDMZ (100) | 10.0.100.50 | Jellyfin media server | microvm (QEMU) |
| ordis | Existing | erebonia | vDMZ (100) | 10.0.100.40 | Reverse proxy, oauth2-proxy, wg-ba gateway | microvm (QEMU) |
| ymir | Existing | erebonia | vMGMT (20) | 10.0.20.41 | Monit system monitoring | microvm (QEMU) |
| roer | Existing | erebonia | vINFRA (11) | 10.0.11.x | Keycloak OIDC identity provider | microvm (QEMU) |
| legram | Existing | erebonia | vINFRA (11) | 10.0.11.x | PKI / certificate authority | microvm (QEMU) |
| trista | Existing | erebonia | vDMZ (100) | 10.0.100.x | Dev environment / task runner | Incus VM |
| (name TBD) | Planned | erebonia | vDMZ (100) | 10.0.100.x | Tailscale control plane (Headscale) | microvm (QEMU) |
| (name TBD) | Planned | erebonia | vDMZ (100) | 10.0.100.60 | Tailscale subnet router | microvm (QEMU) |
| (name TBD) | Planned | erebonia | vDMZ (100) | 10.0.100.x | SSH-only jump host | Incus VM (new) |
| Game servers (TBD) | Planned | erebonia | vDMZ (100) | 10.0.100.7x+ | Game hosting (Minecraft, Factorio, etc.) | TBD |

---

## Existing MicroVMs

### phantasma — DNS & Ad Blocking

| Property | Value |
|----------|-------|
| Host | thebeyond (router) |
| Zone | vINFRA (VLAN 10, migrating to VLAN 11) |
| IP | 10.0.10.2 (will become 10.0.11.2 after VLAN split) |
| Hypervisor | cloud-hypervisor |
| vCPU / RAM | 1 / 512MB |
| Persistent storage | 10MB |
| MAC | 5E:10:AD:01:00:02 |
| Config | `hosts/thebeyond/guests/phantasma/` |

**Services:** Unbound (split-horizon DNS), Adguard Home (DNS filtering), oauth2-proxy
(internal service auth), nginx (TLS termination).

**Planned changes:** Migrates from VLAN 10 to VLAN 11 (vINFRA) during the Secure MGMT
VLAN Split (Step 2). DNS zones migrate from `.local` to `.internal.mutantmell.net` /
`.internal` during Step 4.

---

### ardent — Binary Cache & Git

| Property | Value |
|----------|-------|
| Host | remiferia |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.31 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 1 / 521MB |
| Persistent storage | 10MB |
| MAC | 5E:A5:4D:A3:A0:1A |
| Config | `hosts/remiferia/guests/ardent/` |

**Services:** Attic (Nix binary cache server), Gitea (git repository hosting).

**Planned changes:** None significant. Will get egress filtering (Step 2, Phase 4.4) and
DNS name migration to `.internal.mutantmell.net`.

---

### denai — Development Workstation

| Property | Value |
|----------|-------|
| Host | remiferia |
| Zone | vMGMT (VLAN 20) |
| IP | 10.0.20.40 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 3072MB |
| Persistent storage | 175MB (100MB root + 75MB store overlay) |
| MAC | 5E:A4:B9:D2:F8:03 |
| Config | `hosts/remiferia/guests/denai/` |

**Services:** Build/development environment with aarch64 cross-compilation support, SMB
mounts to remiferia NAS.

**Planned changes:** None significant.

---

### heimdallr — Media Server

| Property | Value |
|----------|-------|
| Host | erebonia |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.50 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 3096MB |
| Persistent storage | 10MB |
| MAC | 5E:45:07:58:F0:82 |
| Config | `hosts/erebonia/guests/heimdallr/` |

**Services:** Jellyfin (media streaming with Intel VAAPI hardware transcoding).

**Planned changes:** Will get native OIDC integration with Keycloak (security
recommendation R2 — survives oauth2-proxy bypass). Egress filtering added in Step 2.

---

### ordis — Reverse Proxy & Web Gateway

| Property | Value |
|----------|-------|
| Host | erebonia |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.40 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 1024MB |
| Persistent storage | 29MB (25MB root + 4MB store overlay) |
| MAC | 5E:41:3F:F4:AB:B4 |
| Config | `hosts/erebonia/guests/ordis/` |

**Services:** nginx (reverse proxy for external-facing services), oauth2-proxy (web
traffic authentication), WireGuard (wg-ba gateway from cloud host).

**Planned changes:**
- New vhosts: `auth.mutantmell.net` (Keycloak proxy), `vpn.mutantmell.net` (Headscale
  proxy) — Steps 4, 7
- SSH daemon removed (replaced by dedicated bastion) — Step 4, Phase 3
- Rate limiting on `/auth/` and `/oauth2/` paths — Step 4, Phase 3
- Egress filtering — Step 2, Phase 4.4

---

### ymir — System Monitoring

| Property | Value |
|----------|-------|
| Host | erebonia |
| Zone | vMGMT (VLAN 20) |
| IP | 10.0.20.41 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 1024MB |
| Persistent storage | 10MB |
| MAC | 5E:A2:E4:CB:05:DA |
| Config | `hosts/erebonia/guests/ymir/` |

**Services:** Monit (infrastructure health monitoring).

**Planned changes:** None significant.

---

### roer — Centralized Identity Provider

| Property | Value |
|----------|-------|
| Host | erebonia |
| Zone | vINFRA (VLAN 11) |
| IP | 10.0.11.x |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 2048MB |
| Persistent storage | ~100GB (PostgreSQL database) |
| Deployed by | Step 4 — Keycloak OIDC (Phase 1) |
| Plan | `keycloak-oauth-oidc-plan.md` |

**Services:** Keycloak (OIDC identity provider), PostgreSQL (user database), nginx
(local reverse proxy, hostname-admin restriction).

**DNS names:**
- External: `auth.mutantmell.net` (proxied through ordis for external users)
- Internal: `roer.internal.mutantmell.net` / `roer.internal`
- Admin console: internal hostname only (security hardening R1)

**Notes:** Replaced Keycloak from the decommissioned gridr VM. Dedicated microvm isolates
the JVM + PostgreSQL attack surface from CA key material. Hosts the `homelab` realm
(replacing current `external` realm). All oauth2-proxy instances, step-ca, headscale,
and services with native OIDC authenticate against this. Hosted on erebonia with a vINFRA
(VLAN 11) bridge interface alongside its existing vDMZ and vMGMT bridges.

---

### legram — PKI / Certificate Authority

| Property | Value |
|----------|-------|
| Host | erebonia |
| Zone | vINFRA (VLAN 11) |
| IP | 10.0.11.x |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 1 / 512MB |
| Persistent storage | Small (badger DB + CA root keys) |
| Deployed by | Step 4 — Keycloak OIDC (Phase 1) |
| Plans | `keycloak-oauth-oidc-plan.md`, `ssh-certificates-sso-plan.md` |

**Services:** step-ca (ACME CA + SSH CA with OIDC provisioner), nginx (TLS termination
for ACME endpoint on :443).

**DNS names:**
- Internal: `legram.internal.mutantmell.net` / `legram.internal`
- ACME endpoint: `https://legram.internal.mutantmell.net/acme/acme/directory`

**Notes:** Replaced step-ca from the decommissioned gridr VM. Separate from Keycloak
(roer) for CA key material isolation — compromise of one doesn't expose the other. OIDC
provisioner validates tokens against roer for SSH certificate issuance. Critical data
(CA root keys) must be backed up. Co-located on erebonia with roer for intra-zone
communication.

---

### trista — Dev Environment / Task Runner

| Property | Value |
|----------|-------|
| Host | erebonia |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.x |
| Hypervisor | Incus VM |
| vCPU / RAM | TBD |
| Persistent storage | TBD |

**Services:** Development environment and task runner.

**DNS names:**
- Internal: `trista.internal.mutantmell.net` / `trista.internal`

**Notes:** Incus VM on erebonia in the DMZ zone. Used as a dev environment and task
runner.

---

## Planned MicroVMs

### (name TBD) — Tailscale Control Plane

*Needs a Trails-series name assigned. Previously "ratatosk" in the Norse naming scheme.*

| Property | Value |
|----------|-------|
| Host | erebonia |
| Zone | vDMZ (VLAN 100) |
| IP | Next available vDMZ address |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 1 / 512MB |
| Persistent storage | Small (SQLite DB, noise private key, ACL policy) |
| Introduced by | Step 7 — Headscale (Phase 1) |
| Plan | `headscale-integration-plan.md` |

**Services:** Headscale (open-source Tailscale control server with embedded DERP relay
+ STUN listener), nginx (TLS termination).

**DNS names:**
- External: `vpn.mutantmell.net` (proxied through ordis)
- Internal: TBD (pending hostname assignment)

**Cross-zone firewall:** Headscale VM (vDMZ) -> roer (vINFRA) on TCP 443 for OIDC
validation.

**Notes:** On vDMZ because embedded DERP/STUN must be reachable from external users.
OIDC integration with roer (Keycloak) for friend authentication. Loss of SQLite DB
means all nodes must re-register.

---

### (name TBD) — Tailscale Subnet Router

*Needs a Trails-series name assigned. Previously "fenrir" in the Norse naming scheme.*

| Property | Value |
|----------|-------|
| Host | erebonia |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.60 (tentative) |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 1 / 256MB |
| Persistent storage | Minimal (Tailscale state) |
| Introduced by | Step 7 — Headscale (Phase 2) |
| Plan | `headscale-integration-plan.md` |

**Services:** Tailscale daemon (subnet router mode, advertises 10.0.100.0/24).

**Notes:** Bridges the Tailscale overlay network into vDMZ. Friends' game traffic
arrives through WireGuard tunnels and gets forwarded to game servers. Headscale ACLs
restrict which IPs/ports friends can actually reach. Lightweight — only runs the
Tailscale daemon.

---

### (name TBD) — SSH Jump Host

*Needs a Trails-series name assigned. Previously "heimdall" in the Norse naming scheme.
Note: "heimdallr" is already used for the Jellyfin media server.*

| Property | Value |
|----------|-------|
| Host | erebonia |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.x (TBD) |
| Hypervisor | **Incus VM** (not a cloud-hypervisor microvm — new capability) |
| vCPU / RAM | 1 / 256MB |
| Persistent storage | None (stateless) |
| Introduced by | Step 4 — Keycloak OIDC (Phase 3) |
| Plan | `keycloak-oauth-oidc-plan.md` |

**Services:** sshd only (hardened, SSH certificates via legram/step-ca).

**Notes:** Replaces SSH access on ordis. Reachable from wg-ba on :22. Uses SSH
certificates for authentication (no key management). Requires figuring out Incus VM
hosting on erebonia — currently only Incus containers are used. This is a **new
hosting capability** that needs to be developed.

---

### Game Servers — Friend-Accessible Game Hosting

*Names, count, and specifics: TBD*

| Property | Value |
|----------|-------|
| Host | erebonia |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.70+ (tentative, per ACL examples) |
| Hypervisor | TBD (microvm or container) |
| vCPU / RAM | Per game requirements |
| Persistent storage | Per game requirements |
| Introduced by | Step 7 — Headscale (Phase 6) |
| Plan | `headscale-integration-plan.md` |

**Notes:** Specific games are deferred — the architecture supports any game server.
Examples from the plan: Minecraft (TCP 25565), Factorio (UDP 34197), Valheim (UDP
2456-2458), Terraria (TCP 7777), Satisfactory (UDP 7777/15000/15777). Friends access
these through the Tailscale overlay via the subnet router. ACLs on headscale control
which ports/IPs each friend group can reach.

---

## Open Questions

1. **Incus VM capability.** The SSH bastion (name TBD) requires running an Incus VM (not
   just a container) on erebonia. This is explicitly called out as a new capability
   that needs to be developed. VM image configuration, NixOS integration, and networking
   with Incus VMs vs containers need to be figured out.

2. **Game server specifics.** Game selection, hosting model (microvm vs container), and
   resource allocation are all deferred.

3. **erebonia capacity.** With all planned VMs assigned to erebonia, it will host
   the most guests by far (heimdallr, ordis, ymir, roer, legram, trista, plus the
   planned Headscale, subnet router, SSH bastion, and game servers). Ensure erebonia has
   sufficient RAM, CPU, and storage — particularly for roer's ~100GB PostgreSQL
   requirement.

4. **vINFRA bridge on erebonia.** roer and legram live on vINFRA (VLAN 11). erebonia
   needs a bridge interface for VLAN 11 alongside its existing vDMZ (VLAN 100) and vMGMT
   (VLAN 20) bridges.

5. **Trails-series names for planned VMs.** The Headscale control plane (was ratatosk),
   subnet router (was fenrir), and SSH bastion (was heimdall) all need Trails-series
   names assigned.

---

## Host Capacity Overview

| Host | Role | Current MicroVMs | Planned MicroVMs | Notes |
|------|------|-----------------|-----------------|-------|
| thebeyond | Router | phantasma | — | cloud-hypervisor; resource-constrained |
| remiferia | NAS + VM host | ardent, denai | — | gridr was decommissioned; freed resources |
| erebonia | VM host + Incus | heimdallr, ordis, ymir, roer, legram, trista | Headscale (TBD), subnet router (TBD), SSH bastion (TBD), game servers | Primary VM host; has vINFRA bridge |
| calvard | VM host | — | — | Currently has no guest VMs |

---

## Implementation Timeline

MicroVMs are introduced across the 7-step implementation roadmap:

| Step | MicroVM Changes |
|------|----------------|
| 1. Zone Refactor | None (pure firewall refactor) |
| 2. Secure MGMT VLAN Split | phantasma migrates from VLAN 10 to VLAN 11; egress filtering added to all vDMZ microvms |
| 3. Network Data Registry | None (data migration) |
| 4. Keycloak OIDC | **Deployed:** roer (Keycloak), legram (step-ca). **Planned:** SSH bastion (name TBD). **Decommissioned:** gridr |
| 5. IP Migration | All microvms get dual addresses (10.0.x.x + 10.97.x.x) |
| 6. SSH Certificates | None (configuration changes to existing hosts) |
| 7. Headscale | **Planned:** Headscale VM (name TBD), subnet router (name TBD). Later: game server microvms |
