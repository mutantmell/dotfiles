# Feature Roadmap Analysis

Cross-plan analysis of all documents in `llm-notes/`, identifying contradictions
and providing a unified implementation guide.

## Plans Analyzed

| Plan | File | Summary |
|------|------|---------|
| Zone Refactor | `zone-refactor-plan.md` | Replace hardcoded trust enum with configurable zone system |
| Secure MGMT VLAN | `secure-mgmt-vlan-plan.md` | Split vMGMT into vMGMT (network gear) + vINFRA (infrastructure) |
| Keycloak OIDC | `keycloak-oauth-oidc-plan.md` | Centralized identity infrastructure with OAuth2/OIDC |
| SSH Certificates | `ssh-certificates-sso-plan.md` | SSH certificate auth via Keycloak + step-ca |
| Headscale | `headscale-integration-plan.md` | Self-hosted Tailscale for friend game server access |

---

## Contradictions

### C1. Network registry zone names vs router6 zone names

**Plans involved:** Secure MGMT VLAN (internal contradiction)

The MGMT VLAN plan's Phase 7 (Network Data Registry) defines zones with descriptive
names, while Phases 1-6 and all other plans use functional zone names:

| VLAN | Router6 zone (Phases 1-6) | Registry zone (Phase 7) |
|------|--------------------------|------------------------|
| 10 (vMGMT) | `network` | `network` |
| 11 (vINFRA) | `management` | `infrastructure` |
| 20 (vHOME) | `trusted` | `home` |
| 30 (vGUEST) | `untrusted` | `guest` |
| 31 (vADU) | *(not defined)* | `adu` |
| 40 (vIOT) | *(not defined)* | `iot` |
| 41 (vGAME) | *(not defined)* | `game` |
| 100 (vDMZ) | *(not defined)* | `dmz` |

The plan explicitly states these should share names: *"They share zone names
deliberately"* and even includes an assertion to enforce sync. But the names don't
match for the three most important zones.

**Impact:** The sync assertion (`builtins.attrNames network.zones ==
builtins.attrNames cfg.zones`) would fail at build time. Either the registry or the
router6 zones need to be renamed to match.

**Resolution options:**

- **Option A: Rename registry zones to match router6.** Keep `management`, `trusted`,
  `untrusted` etc. in the registry. These are the names already used across all other
  plans and the zone refactor. Adds new zones (`adu`, `iot`, `game`, `dmz`) to both
  the registry and router6 as they're defined.

- **Option B: Rename router6 zones to match registry.** Use the more descriptive
  `infrastructure`, `home`, `guest`, `dmz` names in router6. This requires updating
  the zone refactor plan, all host configs, and all other plans that reference zone
  names. Larger blast radius but more readable names.

- **Option C (Recommended): Decouple the naming.** The registry zones represent the
  *network topology* (which VLAN a host is on). The router6 zones represent *firewall
  policy* (what traffic is allowed). These don't need to have a 1:1 mapping — multiple
  VLANs could share a firewall policy zone (e.g., vADU and vGUEST might both use the
  `untrusted` firewall zone). Remove the sync assertion and instead have the registry
  store both the topology zone name and the firewall zone name:
  ```nix
  zones = {
    infrastructure = { vlanId = 11; firewallZone = "management"; };
    home           = { vlanId = 20; firewallZone = "trusted"; };
    guest          = { vlanId = 30; firewallZone = "untrusted"; };
    # ...
  };
  ```
  This preserves the descriptive topology names while keeping the functional firewall
  zone names stable across all plans.

---

### C2. Headscale on vINFRA is incompatible with the network architecture

**Plans involved:** Headscale, Secure MGMT VLAN, Keycloak OIDC

The Headscale plan places headscale on vINFRA and requires two internet-reachable
network surfaces:

1. **DERP relay** (TCP 443) — relays encrypted WireGuard packets when direct
   connections fail. DERP is embedded in headscale and cannot be separated into a
   standalone service.
2. **STUN** (UDP 3478) — helps Tailscale clients discover their public IP for NAT
   traversal. Also embedded in headscale.

The plan proposes a WAN port forward (UDP 3478) from the router to the headscale
microvm on vINFRA, with DERP proxied through surtr. This has two problems:

**Problem 1: No direct WAN path exists.** The network architecture routes all
external traffic through a cloud host via the wg-ba WireGuard tunnel to surtr on
vDMZ. There is no direct WAN exposure of the homelab's public IP — port forwards
from the WAN interface don't fit this architecture. STUN served through a WireGuard
tunnel would report the tunnel endpoint IP rather than the client's actual public
IP, breaking NAT traversal entirely.

**Problem 2: DERP is embedded, not separable.** The plan's DERP server runs inside
the headscale process. You cannot split just DERP/STUN to vDMZ while keeping
headscale's control plane on vINFRA — they're the same binary, same process.

**Impact:** As written, headscale's STUN and DERP cannot function on vINFRA. Friends'
Tailscale clients would be unable to perform NAT traversal (STUN) or relay traffic
(DERP) through the homelab.

**Resolution: Move headscale entirely to vDMZ.**

Since DERP and STUN are embedded in headscale and both need to be reachable from
external users, headscale itself must live on vDMZ. This aligns with the broader
architecture: vDMZ is where services reachable by external untrusted users belong.

Changes required to the Headscale plan:

| Aspect | Current (vINFRA) | Updated (vDMZ) |
|--------|-----------------|----------------|
| Microvm host | vINFRA host (jotunheimr or muspelheim) | muspelheim (vDMZ, alongside surtr/fenrir) |
| Network | VLAN 11 (vINFRA) | VLAN 100 (vDMZ) |
| Keycloak OIDC | Intra-zone (vINFRA → vINFRA) | Cross-zone, explicit firewall rule (vDMZ → vINFRA), same pattern as surtr → Keycloak |
| Control plane proxy | Proxied through surtr | Can be proxied through surtr (intra-zone on vDMZ) or served directly |
| DERP/STUN reachability | WAN port forward (broken) | Reachable via cloud host → wg-ba → headscale, or via surtr proxy |
| Compromise impact | Attacker on vINFRA (worse) | Attacker on vDMZ (better — same as any DMZ service compromise) |

The cross-zone firewall rule for headscale → Keycloak follows the established
pattern. Add to `extraForwardRules`:

```nix
{
  iifname = "vDMZ.br0";
  oifname = "vINFRA.br0";
  ip.saddr = "<headscale-microvm-ip>";
  ip.daddr = "<keycloak-microvm-ip>";
  tcp.dport = 443;
  verdict = "accept";
  comment = "headscale -> Keycloak (OIDC)";
}
```

For DERP and STUN reachability from friends, the traffic path would be:
- **DERP relay (HTTPS):** Friend → cloud host → wg-ba → surtr (proxy for
  `vpn.mutantmell.net`) → headscale on vDMZ. Same path as the control plane.
- **STUN (UDP 3478):** Needs investigation. UDP cannot be proxied through nginx.
  Options include: forwarding STUN UDP through the wg-ba tunnel to headscale on
  vDMZ (may work since the cloud host sees the friend's real IP and can relay the
  STUN response), running a standalone STUN service on the cloud host itself, or
  accepting that STUN won't work and relying on DERP relay for all connections
  (higher latency but functional).

Moving headscale to vDMZ also improves the security posture: a compromise of
headscale now gives an attacker a vDMZ foothold (same as compromising any game
server) rather than a vINFRA foothold (which would put them alongside Keycloak,
step-ca, and DNS). The original plan's argument that "headscale is infrastructure"
is reasonable in the abstract, but the embedded DERP/STUN requirement makes
vINFRA placement impractical.

---

## Implementation Guide

### Dependency Graph

```
Zone Refactor ──→ Secure MGMT VLAN Split (Phases 1-6) ──→ IP Migration (Phase 8)
                          │                                       │
                          ├──→ Network Data Registry (Phase 7)    │
                          │                                       │
                          ▼                                       │
                  Keycloak OIDC ──────────────────────────────────┘
                     │    │                          (update IPs)
                     │    │
                     ▼    ▼
              SSH Certs  Headscale
```

### Recommended Implementation Order

The plans should be implemented in the following order. Each step builds on the
previous ones and is independently deployable — you get working infrastructure at
each stage.

---

#### Step 1: Zone Refactor

**Plan:** `zone-refactor-plan.md` (all phases)

**What it does:** Replaces the hardcoded trust enum with a configurable zone system.
Pure refactor — generated nftables output must be identical.

**Why first:** Every other plan depends on the zone system. The MGMT VLAN plan's
`network` zone, the Keycloak plan's firewall rules, and the Headscale plan's
`extraForwardRules` all require configurable zones.

**Key context:**
- This is the highest-risk step (firewall misconfiguration can break everything) but
  also the most testable (snapshot tests ensure identical output)
- Phase 0 (test coverage) must be completed before touching any firewall code
- Use `magic_rollback` with deploy-rs when deploying to the router
- All host configs get a mechanical `trust = "..."` → `zone = "..."` rename

**Deliverable:** Zone system in place, all tests passing, identical firewall behavior.

---

#### Step 2: Secure MGMT VLAN Split (Phases 1-6)

**Plan:** `secure-mgmt-vlan-plan.md` Phases 1 through 6

**What it does:** Creates the vINFRA VLAN (VLAN 11), defines the `network` zone,
migrates infrastructure hosts, hardens NFS, adds host firewalls, and updates OpenWRT.

**Why second:** This establishes the network topology that all subsequent plans
assume (vINFRA for infrastructure services, vMGMT locked down for network gear).
Keycloak, step-ca, and headscale microvms all need vINFRA to exist.

**Key context:**
- Deploy in the order specified in Phase 6.2: VM guests → VM hosts → NAS → Router
- DNS is the most fragile piece — verify alfheim's Unbound config extensively before
  deploying the router change
- The management zone's internet access changes from blanket `accessTo` to filtered
  `forwardRules.external` — verify updates/package downloads still work
- NFS mount changes (Phase 3) should be tested before deploying host firewalls
  (Phase 4), since the firewalls will block NFS from unexpected sources

**Deliverable:** vMGMT locked down to network gear only, vINFRA operational with all
infrastructure hosts, host firewalls active, OpenWRT APs updated.

---

#### Step 3: Network Data Registry

**Plan:** `secure-mgmt-vlan-plan.md` Phase 7

**What it does:** Replaces `network.json` with a Nix-based registry that derives all
addresses (IPv4, IPv6, legacy IPv4) from zone + host ID.

**Why here:** Having the registry in place before the Keycloak plan simplifies the
DNS migration — new DNS records can be generated programmatically from the registry.
It also simplifies the IP migration (Phase 8) by providing `legacyPrefix` support.

**Key context:**
- The zone naming issue (C1) must be resolved before implementing this
- Start by creating `network.nix` alongside `network.json` (both active), then
  gradually migrate consumers
- The `nix run .#netinfo` app provides immediate value for looking up addresses
- Don't try to replace all hardcoded IPs at once — do it file-by-file as you
  touch configs in subsequent steps

**Deliverable:** `lib/common/data/network.nix` in place, `netinfo` app working,
hardcoded IPs gradually being replaced.

---

#### Step 4: Keycloak OIDC (Phases 1-3)

**Plan:** `keycloak-oauth-oidc-plan.md` Phases 1, 2, and 3

**What it does:**
- Phase 1: Provisions Keycloak and step-ca microvms on vINFRA, migrates from gridr,
  deploys oauth2-proxy on alfheim, applies security fixes (S1-S3, S7)
- Phase 2: Creates `homelab` realm, registers clients, sets up groups/roles
- Phase 3: Implements split-horizon DNS (`mutantmell.net` hierarchy), deploys
  SSH bastion on vDMZ, enables external access via cloud host

**Why here:** Keycloak is a prerequisite for both SSH certificates and Headscale
OIDC integration. The DNS migration in Phase 3 resolves the `.local` naming issues
across all plans.

**Key context:**
- Phase 1 can proceed before DNS migration — Keycloak initially uses current names
- Phase 3 (DNS migration) is a coordinated change across many files. Use the network
  registry to generate the new DNS records programmatically.
- The SSH bastion requires Incus VM support (currently only containers are used) —
  this is a new capability that needs investigation
- All security findings (S1-S13) should be addressed as the relevant phases execute
- After Phase 3, the `.local` DNS records from the MGMT VLAN plan will be superseded
  by the new `mutantmell.net` naming hierarchy

**Deliverable:** Keycloak on dedicated vINFRA microvm, step-ca on dedicated vINFRA
microvm, split-horizon DNS operational, external access working through cloud host,
gridr decommissioned.

---

#### Step 5: IP Migration

**Plan:** `secure-mgmt-vlan-plan.md` Phase 8

**What it does:** Adds `10.97.x.x` dual addresses alongside `10.0.x.x` on all VLANs
and hosts, preparing for eventual removal of the `10.0.x.x` range.

**Why here:** The VLAN split is stable, DNS is migrated, and the network registry can
generate both address ranges. Doing this before SSH certs and Headscale means those
plans can be written against the final `10.97.x.x` addresses.

**Key context:**
- The network registry's `legacyPrefix` feature handles dual-address generation
- DHCP pool migration needs careful handling — consider switching pools to
  `10.97.x.x` only and letting old leases expire
- WireGuard client configs (personal devices) need manual updates to add
  `10.97.0.0/16` to AllowedIPs
- Don't remove `10.0.x.x` addresses until all services are confirmed working on
  `10.97.x.x` — use the appendix checklist in the MGMT VLAN plan

**Deliverable:** All hosts reachable on both `10.0.x.x` and `10.97.x.x`, services
working on new range.

---

#### Step 6: SSH Certificates

**Plan:** `ssh-certificates-sso-plan.md` (all phases)

**What it does:** Deploys SSH certificate authentication via step-ca's OIDC
provisioner, replacing static SSH keys with short-lived certificates.

**Why here:** Depends on Keycloak (Phase 4) being fully operational with the
`homelab` realm and groups configured. step-ca's OIDC provisioner needs a working
Keycloak.

**Key context:**
- The SSH cert plan uses placeholder DNS names (`*.home.local`) and realm name
  (`home`) — these will be resolved to the canonical names (`*.mutantmell.net`,
  `homelab`) established by the Keycloak OIDC plan (Step 4) when this step executes
- Host certificates can be signed during this step for all NixOS hosts
- The MAC allowlist on vMGMT remains until Phase 6 of this plan (when it's
  removed in favor of certificate-based auth)
- CI/CD integration (client credentials grant) should be tested alongside
  interactive certificate issuance
- OpenWRT devices keep traditional SSH key auth — this is explicitly designed

**Deliverable:** SSH certificate auth working for admin access, host certificates
eliminating TOFU, CI/CD using short-lived certificates.

---

#### Step 7: Headscale

**Plan:** `headscale-integration-plan.md` (all phases)

**What it does:** Deploys Headscale as a self-hosted Tailscale control plane,
with a subnet router on vDMZ for friend access to game servers.

**Why last:** Depends on Keycloak OIDC (for friend authentication), split-horizon
DNS (for `vpn.mutantmell.net`), and surtr proxying (for external access to the
control plane). All of these are established in previous steps.

**Key context:**
- The headscale plan must be updated to place headscale on vDMZ instead of
  vINFRA (C2) before implementation begins
- Can start Phase 1 (deploy headscale) with pre-auth keys before Keycloak OIDC
  is wired up — useful for testing the control plane independently
- STUN reachability for friends needs investigation — UDP through the cloud host
  wg-ba tunnel may or may not preserve the source IP information STUN needs
- ACL policy is a separate JSON file — adding game servers and friends doesn't
  require NixOS rebuilds
- headscale → Keycloak needs an explicit cross-zone firewall rule (vDMZ → vINFRA),
  same pattern as surtr → Keycloak
- The subnet router (fenrir) is already on vDMZ — with headscale also on vDMZ,
  fenrir → headscale becomes intra-zone (no firewall rule needed)
- Update ACL IPs to use `10.97.x.x` if the IP migration (Step 5) is complete

**Deliverable:** Friends can install Tailscale, authenticate via Keycloak, and
connect to game servers. Full self-hosted, no Tailscale Inc. dependency.

---

### Steps That Can Be Parallelized

While the overall order above is sequential, some work can overlap:

- **Steps 6 and 7** (SSH Certificates and Headscale) are independent of each other
  and can be worked on in parallel after Step 4 is complete
- **Step 3** (Network Registry) can be started during Step 2 — create the registry
  file early and begin migrating consumers as you touch host configs
- **Step 5** (IP Migration) can begin during Step 4 — add dual addresses to router
  VLANs while working on Keycloak, since the dual-address mechanism is independent
  of identity infrastructure

### Not Contradictions: Sequencing Differences

The following differences between plans are **not contradictions** — they reflect
the natural progression of the implementation order, where earlier plans work with
current infrastructure and later plans replace it.

**DNS naming (`.local` → `.mutantmell.net`):** The SSH Certificates plan uses
`*.home.local` and the Secure MGMT VLAN plan uses `*.local` because both are
written against the current DNS infrastructure. The Keycloak OIDC plan (Step 4)
performs the bulk DNS migration to `*.internal.mutantmell.net` / `*.internal` /
`*.mutantmell.net`. When the SSH Certificates plan (Step 6) is implemented, it
will use the canonical names established by the already-completed Keycloak plan.

**Keycloak realm name (`home` vs `homelab`):** The SSH Certificates plan uses
`home` as a placeholder realm name. The Keycloak OIDC plan (Step 4) defines the
authoritative realm as `homelab`. When the SSH Certificates plan (Step 6) is
implemented, it will reference the `homelab` realm that already exists.

### Cross-Plan Updates Needed After Resolving Contradictions

| File | Updates Needed |
|------|---------------|
| `secure-mgmt-vlan-plan.md` | Resolve zone name mismatch in Phase 7 registry (C1) |
| `headscale-integration-plan.md` | Move headscale from vINFRA to vDMZ, update VLAN placement rationale, update firewall rules, investigate STUN reachability via cloud host (C2) |
| `keycloak-oauth-oidc-plan.md` | No changes needed |
| `ssh-certificates-sso-plan.md` | No changes needed (placeholder names will be resolved at implementation time) |
| `zone-refactor-plan.md` | No changes needed (self-contained, no DNS or Keycloak references) |
