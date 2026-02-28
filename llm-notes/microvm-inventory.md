# MicroVM Inventory

> **NOTE**: This document uses outdated Norse mythology hostnames. Hosts have been
> renamed to a Trails series theme. See `docs/hostnames.md` for the canonical
> hostname reference.

Comprehensive inventory of all microvms — existing and planned — derived from the
implementation plans in `llm-notes/`.

## Summary Table

| Name | Status | Host | Zone (VLAN) | IP Address | Purpose | Hypervisor |
|------|--------|------|-------------|------------|---------|------------|
| alfheim | Existing | yggdrasil | vINFRA (10) | 10.0.10.2 | DNS, DHCP, Adguard Home, oauth2-proxy | cloud-hypervisor |
| gridr | Existing (to decommission) | jotunheimr | vMGMT (20) | 10.0.20.30 | Keycloak, step-ca, nginx | microvm (QEMU) |
| hrungnir | Existing | jotunheimr | vDMZ (100) | 10.0.100.31 | Attic binary cache, Gitea | microvm (QEMU) |
| skadi | Existing | jotunheimr | vMGMT (20) | 10.0.20.40 | Development workstation | microvm (QEMU) |
| bragi | Existing | muspelheim | vDMZ (100) | 10.0.100.50 | Jellyfin media server | microvm (QEMU) |
| surtr | Existing | muspelheim | vDMZ (100) | 10.0.100.40 | Reverse proxy, oauth2-proxy, wg-ba gateway | microvm (QEMU) |
| ymir | Existing | muspelheim | vMGMT (20) | 10.0.20.41 | Monit system monitoring | microvm (QEMU) |
| mimir | Planned | muspelheim | vINFRA (11) | 10.0.11.x | Keycloak OIDC identity provider | microvm (QEMU) |
| tyr | Planned | muspelheim | vINFRA (11) | 10.0.11.x | PKI / certificate authority | microvm (QEMU) |
| ratatosk | Planned | muspelheim | vDMZ (100) | 10.0.100.x | Tailscale control plane (Headscale) | microvm (QEMU) |
| fenrir | Planned | muspelheim | vDMZ (100) | 10.0.100.60 | Tailscale subnet router | microvm (QEMU) |
| heimdall | Planned | muspelheim | vDMZ (100) | 10.0.100.x | SSH-only jump host | Incus VM (new) |
| Game servers (TBD) | Planned | muspelheim | vDMZ (100) | 10.0.100.7x+ | Game hosting (Minecraft, Factorio, etc.) | TBD |

---

## Existing MicroVMs

### alfheim — DNS & Ad Blocking

| Property | Value |
|----------|-------|
| Host | yggdrasil (router) |
| Zone | vINFRA (VLAN 10, migrating to VLAN 11) |
| IP | 10.0.10.2 (will become 10.0.11.2 after VLAN split) |
| Hypervisor | cloud-hypervisor |
| vCPU / RAM | 1 / 512MB |
| Persistent storage | 10MB |
| MAC | 5E:10:AD:01:00:02 |
| Config | `hosts/yggdrasil/guests/alfheim/` |

**Services:** Unbound (split-horizon DNS), Adguard Home (DNS filtering), oauth2-proxy
(internal service auth), nginx (TLS termination).

**Planned changes:** Migrates from VLAN 10 to VLAN 11 (vINFRA) during the Secure MGMT
VLAN Split (Step 2). DNS zones migrate from `.local` to `.internal.mutantmell.net` /
`.internal` during Step 4.

---

### gridr — Identity & Certificates (to be decommissioned)

| Property | Value |
|----------|-------|
| Host | jotunheimr |
| Zone | vMGMT (VLAN 20) |
| IP | 10.0.20.30 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 1024MB |
| Persistent storage | 100MB |
| MAC | 5E:6D:F8:D1:E8:AA |
| Config | `hosts/jotunheimr/guests/gridr/` |

**Services:** Keycloak (OAuth2/OIDC on :9080), step-ca (PKI/CA on :9443), nginx (TLS
termination & ACME endpoint).

**Planned changes:** Will be **decommissioned** during Step 4 (Keycloak OIDC). Keycloak
and step-ca split into separate dedicated microvms on vINFRA (VLAN 11) for better
isolation. gridr currently bundles both services, meaning a Keycloak compromise also
exposes CA key material.

---

### hrungnir — Binary Cache & Git

| Property | Value |
|----------|-------|
| Host | jotunheimr |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.31 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 1 / 521MB |
| Persistent storage | 10MB |
| MAC | 5E:A5:4D:A3:A0:1A |
| Config | `hosts/jotunheimr/guests/hrungnir/` |

**Services:** Attic (Nix binary cache server), Gitea (git repository hosting).

**Planned changes:** None significant. Will get egress filtering (Step 2, Phase 4.4) and
DNS name migration to `.internal.mutantmell.net`.

---

### skadi — Development Workstation

| Property | Value |
|----------|-------|
| Host | jotunheimr |
| Zone | vMGMT (VLAN 20) |
| IP | 10.0.20.40 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 3072MB |
| Persistent storage | 175MB (100MB root + 75MB store overlay) |
| MAC | 5E:A4:B9:D2:F8:03 |
| Config | `hosts/jotunheimr/guests/skadi/` |

**Services:** Build/development environment with aarch64 cross-compilation support, SMB
mounts to jotunheimr NAS.

**Planned changes:** None significant.

---

### bragi — Media Server

| Property | Value |
|----------|-------|
| Host | muspelheim |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.50 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 3096MB |
| Persistent storage | 10MB |
| MAC | 5E:45:07:58:F0:82 |
| Config | `hosts/muspelheim/guests/bragi/` |

**Services:** Jellyfin (media streaming with Intel VAAPI hardware transcoding).

**Planned changes:** Will get native OIDC integration with Keycloak (security
recommendation R2 — survives oauth2-proxy bypass). Egress filtering added in Step 2.

---

### surtr — Reverse Proxy & Web Gateway

| Property | Value |
|----------|-------|
| Host | muspelheim |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.40 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 1024MB |
| Persistent storage | 29MB (25MB root + 4MB store overlay) |
| MAC | 5E:41:3F:F4:AB:B4 |
| Config | `hosts/muspelheim/guests/surtr/` |

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
| Host | muspelheim |
| Zone | vMGMT (VLAN 20) |
| IP | 10.0.20.41 |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 1024MB |
| Persistent storage | 10MB |
| MAC | 5E:A2:E4:CB:05:DA |
| Config | `hosts/muspelheim/guests/ymir/` |

**Services:** Monit (infrastructure health monitoring).

**Planned changes:** None significant.

---

## Planned MicroVMs

### mimir — Centralized Identity Provider

*Named after Mímir, the wise guardian of the Well of Wisdom — keeper of knowledge and
identity, from whom even Odin sought counsel.*

| Property | Value |
|----------|-------|
| Host | muspelheim |
| Zone | vINFRA (VLAN 11, new) |
| IP | 10.0.11.x (TBD) |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 2 / 2048MB |
| Persistent storage | ~100GB (PostgreSQL database) |
| Introduced by | Step 4 — Keycloak OIDC (Phase 1) |
| Plan | `keycloak-oauth-oidc-plan.md` |

**Services:** Keycloak (OIDC identity provider), PostgreSQL (user database), nginx
(local reverse proxy, hostname-admin restriction).

**DNS names:**
- External: `auth.mutantmell.net` (proxied through surtr for external users)
- Internal: `mimir.internal.mutantmell.net` / `mimir.internal`
- Admin console: internal hostname only (security hardening R1)

**Notes:** Replaces Keycloak on gridr. Dedicated microvm isolates the JVM + PostgreSQL
attack surface from CA key material. Hosts the `homelab` realm (replacing current
`external` realm). All oauth2-proxy instances, step-ca, headscale, and services with
native OIDC authenticate against this. Hosted on muspelheim, which requires a new vINFRA
(VLAN 11) bridge interface alongside its existing vDMZ and vMGMT bridges.

---

### tyr — PKI / Certificate Authority

*Named after Týr, god of law, oaths, and binding agreements — the authority whose word
forges trust, just as a CA's signature binds identity to key.*

| Property | Value |
|----------|-------|
| Host | muspelheim |
| Zone | vINFRA (VLAN 11, new) |
| IP | 10.0.11.x (TBD) |
| Hypervisor | microvm (QEMU) |
| vCPU / RAM | 1 / 512MB |
| Persistent storage | Small (badger DB + CA root keys) |
| Introduced by | Step 4 — Keycloak OIDC (Phase 1) |
| Plans | `keycloak-oauth-oidc-plan.md`, `ssh-certificates-sso-plan.md` |

**Services:** step-ca (ACME CA + SSH CA with OIDC provisioner), nginx (TLS termination
for ACME endpoint on :443).

**DNS names:**
- Internal: `tyr.internal.mutantmell.net` / `tyr.internal`
- ACME endpoint: `https://tyr.internal.mutantmell.net/acme/acme/directory`

**Notes:** Replaces step-ca on gridr. Separate from Keycloak (mimir) for CA key material
isolation — compromise of one doesn't expose the other. OIDC provisioner validates
tokens against mimir for SSH certificate issuance. Critical data (CA root keys) must
be backed up. Co-located on muspelheim with mimir for intra-zone communication.

---

### ratatosk — Tailscale Control Plane

*Named after Ratatoskr, the squirrel that runs between realms along Yggdrasil carrying
messages — a coordinator and go-between, just as Headscale coordinates nodes across
networks.*

| Property | Value |
|----------|-------|
| Host | muspelheim |
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
- External: `vpn.mutantmell.net` (proxied through surtr)
- Internal: `ratatosk.internal.mutantmell.net` / `ratatosk.internal`

**Cross-zone firewall:** ratatosk (vDMZ) -> mimir (vINFRA) on TCP 443 for OIDC
validation.

**Notes:** On vDMZ because embedded DERP/STUN must be reachable from external users.
OIDC integration with mimir (Keycloak) for friend authentication. Loss of SQLite DB
means all nodes must re-register.

---

### fenrir — Tailscale Subnet Router

| Property | Value |
|----------|-------|
| Host | muspelheim |
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

### heimdall — SSH Jump Host

*Named after Heimdall, the ever-vigilant watchman of Bifrost who sees and hears all who
approach — the gatekeeper through whom one must pass to enter the realm of the gods.*

| Property | Value |
|----------|-------|
| Host | muspelheim |
| Zone | vDMZ (VLAN 100) |
| IP | 10.0.100.x (TBD) |
| Hypervisor | **Incus VM** (not a cloud-hypervisor microvm — new capability) |
| vCPU / RAM | 1 / 256MB |
| Persistent storage | None (stateless) |
| Introduced by | Step 4 — Keycloak OIDC (Phase 3) |
| Plan | `keycloak-oauth-oidc-plan.md` |

**Services:** sshd only (hardened, SSH certificates via tyr/step-ca).

**Notes:** Replaces SSH access on surtr. Reachable from wg-ba on :22. Uses SSH
certificates for authentication (no key management). Requires figuring out Incus VM
hosting on muspelheim — currently only Incus containers are used. This is a **new
hosting capability** that needs to be developed.

---

### Game Servers — Friend-Accessible Game Hosting

*Names, count, and specifics: TBD*

| Property | Value |
|----------|-------|
| Host | muspelheim |
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
these through the Tailscale overlay via fenrir. ACLs on headscale control which
ports/IPs each friend group can reach.

---

## Open Questions

1. **Incus VM capability.** heimdall (SSH bastion) requires running an Incus VM (not
   just a container) on muspelheim. This is explicitly called out as a new capability
   that needs to be developed. VM image configuration, NixOS integration, and networking
   with Incus VMs vs containers need to be figured out.

2. **Game server specifics.** Game selection, hosting model (microvm vs container), and
   resource allocation are all deferred.

3. **muspelheim capacity.** With all planned VMs assigned to muspelheim, it will host
   the most guests by far (bragi, surtr, ymir, mimir, tyr, ratatosk, fenrir, heimdall,
   plus game servers). Ensure muspelheim has sufficient RAM, CPU, and storage —
   particularly for mimir's ~100GB PostgreSQL requirement.

4. **vINFRA bridge on muspelheim.** mimir and tyr live on vINFRA (VLAN 11), which is a
   new VLAN. muspelheim needs a new bridge interface for VLAN 11 alongside its existing
   vDMZ (VLAN 100) and vMGMT (VLAN 20) bridges.

---

## Host Capacity Overview

| Host | Role | Current MicroVMs | Planned MicroVMs | Notes |
|------|------|-----------------|-----------------|-------|
| yggdrasil | Router | alfheim | — | cloud-hypervisor; resource-constrained |
| jotunheimr | NAS + VM host | gridr, hrungnir, skadi | — | gridr to be decommissioned; frees resources |
| muspelheim | VM host + Incus | bragi, surtr, ymir | mimir, tyr, ratatosk, fenrir, heimdall, game servers | Primary VM host; needs vINFRA bridge |
| vanaheim | VM host | — | — | Currently has no guest VMs |

---

## Implementation Timeline

MicroVMs are introduced across the 7-step implementation roadmap:

| Step | MicroVM Changes |
|------|----------------|
| 1. Zone Refactor | None (pure firewall refactor) |
| 2. Secure MGMT VLAN Split | alfheim migrates from VLAN 10 to VLAN 11; egress filtering added to all vDMZ microvms |
| 3. Network Data Registry | None (data migration) |
| 4. Keycloak OIDC | **New:** mimir (Keycloak), tyr (step-ca), heimdall (SSH bastion). **Decommission:** gridr |
| 5. IP Migration | All microvms get dual addresses (10.0.x.x + 10.97.x.x) |
| 6. SSH Certificates | None (configuration changes to existing hosts) |
| 7. Headscale | **New:** ratatosk (Headscale), fenrir (subnet router). Later: game server microvms |
