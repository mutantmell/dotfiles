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

### C1. DNS naming: `.home.local` vs `.local` vs `.mutantmell.net`

**Plans involved:** SSH Certificates, Secure MGMT VLAN, Keycloak OIDC, Headscale

The plans use three different DNS naming conventions for the same hosts:

| Plan | DNS scheme | Example |
|------|-----------|---------|
| SSH Certificates | `*.home.local` | `auth.home.local`, `target-host.local` |
| Secure MGMT VLAN | `*.local` | `yggdrasil.local`, `alfheim.local`, `gridr.local` |
| Keycloak OIDC | `*.internal.mutantmell.net` + `*.internal` | `auth.mutantmell.net`, `alfheim.internal` |
| Headscale | `*.internal.mutantmell.net` + `*.internal` | `headscale.internal`, `vpn.mutantmell.net` |

The Keycloak OIDC plan explicitly mandates migrating away from `.local` (Phase 3)
because `.local` conflicts with mDNS (RFC 6762). The SSH Certificates plan uses
`home.local` which is a subdomain of `.local` and would also be removed. The Secure
MGMT VLAN plan uses the current `.local` names throughout.

**Impact:** The SSH Certificates plan has hardcoded URLs like
`auth.home.local/realms/home` that won't exist after the Keycloak OIDC plan's DNS
migration. The Secure MGMT VLAN plan's DNS records, `extraHosts`, and Unbound
`local-data` entries all use `.local` and would be overwritten by the Keycloak plan.

**Resolution options:**

- **Option A (Recommended): Adopt `mutantmell.net` hierarchy everywhere.** The
  Keycloak OIDC plan's DNS strategy is the most thoroughly considered. Update the SSH
  Certificates plan and Secure MGMT VLAN plan to use `*.internal.mutantmell.net` /
  `*.internal` / `*.mutantmell.net` instead of `.local`. This means:
  - SSH cert plan: `auth.home.local` → `auth.mutantmell.net`
  - SSH cert plan: `target-host.local` → `target-host.internal`
  - MGMT VLAN plan: all `.local` references → `.internal` / `.internal.mutantmell.net`

- **Option B: Defer DNS migration, use `.local` temporarily.** Implement the MGMT
  VLAN plan with `.local` as written, then do a bulk rename when the Keycloak plan's
  Phase 3 executes. More churn but allows the MGMT VLAN plan to proceed without
  coupling to the Keycloak plan's DNS strategy.

---

### C2. Keycloak realm name: `home` vs `homelab`

**Plans involved:** SSH Certificates, Keycloak OIDC, Headscale

The SSH Certificates plan references a Keycloak realm named `home`:
- OIDC issuer URL: `https://auth.home.local/realms/home`
- Token exchange URL: `https://auth.home.local/realms/home/protocol/openid-connect/token`

The Keycloak OIDC plan defines the realm as `homelab`:
- OIDC issuer URL: `https://auth.mutantmell.net/auth/realms/homelab`

The Headscale plan follows the Keycloak OIDC plan and uses `homelab`.

**Impact:** If implemented as-written, step-ca's OIDC provisioner would point at a
nonexistent realm. Token issuer validation would fail.

**Resolution options:**

- **Option A (Recommended): Use `homelab` everywhere.** The Keycloak OIDC plan is
  the authoritative source for realm configuration. Update the SSH Certificates plan
  to reference `homelab` instead of `home`.

- **Option B: Use `home`.** Shorter, simpler. Update the Keycloak and Headscale plans.
  No functional difference — it's just a name.

---

### C3. Network registry zone names vs router6 zone names

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

### C4. STUN port forward creates direct internet exposure for vINFRA

**Plans involved:** Headscale, Secure MGMT VLAN

The Headscale plan requires a UDP port forward from the WAN interface to the
headscale microvm on vINFRA (UDP 3478 for STUN). The headscale plan acknowledges
this: *"The headscale microvm stays on vINFRA with no direct internet exposure
except the STUN port forwarded through the router."*

However, a core principle of the MGMT VLAN plan and Keycloak OIDC plan is that
vINFRA services are never directly internet-accessible. All external access is
proxied through surtr on vDMZ. The STUN port forward breaks this principle by
creating a direct internet → vINFRA data path.

**Impact:** A vulnerability in headscale's embedded STUN server would provide direct
access to a vINFRA host, bypassing the vDMZ chokepoint entirely.

**Resolution options:**

- **Option A: Accept the exception.** STUN is a minimal UDP protocol (RFC 5389) with
  a tiny attack surface. The port forward goes to a specific port on a specific host.
  headscale verifies connecting clients against its node database. Document this as a
  known exception to the "no direct vINFRA exposure" rule.

- **Option B (Recommended): Run a separate DERP/STUN relay on vDMZ.** Instead of
  using headscale's embedded DERP server, deploy a standalone
  `tailscale/derper` instance on vDMZ (could run on the fenrir subnet router, or a
  dedicated microvm). This keeps all internet-facing network surfaces on vDMZ.
  Headscale on vINFRA handles only the control plane (HTTPS, proxied through surtr).
  The DERP relay on vDMZ handles data plane relay and STUN.

- **Option C: Use Tailscale's public DERP servers for STUN only.** Keep the
  self-hosted DERP relay on headscale for encrypted relay traffic, but let Tailscale's
  public STUN servers handle NAT traversal. This avoids the port forward entirely but
  introduces a dependency on Tailscale Inc. for STUN (not for relay data).

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
- If **C1 Option A** is chosen, consider using `.internal` names from the start
  instead of `.local`, since the Keycloak plan will replace them anyway. This
  avoids doing the DNS rename twice. If **C1 Option B** is chosen, use `.local` as
  written and plan for the bulk rename later.
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
- The zone naming issue (C3) must be resolved before implementing this
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
- After Phase 3, update the MGMT VLAN plan's DNS records and `extraHosts` entries
  to use the new naming scheme (if C1 Option B was chosen and they still use `.local`)

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
- Update the plan to use `auth.mutantmell.net` instead of `auth.home.local` (C1)
- Update the plan to use realm `homelab` instead of `home` (C2)
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
- Can start Phase 1 (deploy headscale) with pre-auth keys before Keycloak OIDC
  is wired up — useful for testing the control plane independently
- The STUN port forward question (C4) should be decided before deployment
- ACL policy is a separate JSON file — adding game servers and friends doesn't
  require NixOS rebuilds
- The subnet router (fenrir) on vDMZ needs the same firewall rule pattern as
  surtr → Keycloak (explicit `extraForwardRules` for vDMZ → vINFRA)
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

### Cross-Plan Updates Needed After Resolving Contradictions

Once the contradictions above are resolved, these plan files need updates:

| File | Updates Needed |
|------|---------------|
| `ssh-certificates-sso-plan.md` | Replace `*.home.local` with `*.mutantmell.net` / `*.internal` naming (C1); replace realm `home` with `homelab` (C2) |
| `secure-mgmt-vlan-plan.md` | Resolve zone name mismatch in Phase 7 registry (C3); optionally pre-adopt `*.internal` naming instead of `.local` (C1) |
| `headscale-integration-plan.md` | Resolve STUN/DERP placement for vINFRA exposure (C4) |
| `keycloak-oauth-oidc-plan.md` | No changes needed (this plan is the most internally consistent and is the source of truth for DNS and realm naming) |
| `zone-refactor-plan.md` | No changes needed (this plan is self-contained and does not reference DNS names or Keycloak) |
