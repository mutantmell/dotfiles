# vLAB Zone Implementation Plan

## Context

Create a dedicated `lab` zone for development environments where untrusted code
runs (edith, trista, future dev environments). The laptop VPN (`wg-vpn`) needs
access to edith for the thin client workflow, but edith currently sits on the
`trusted` zone (VLAN 20) which the VPN zone intentionally cannot reach.

The `lab` zone is semi-trusted: machines that run arbitrary user code (AI
workloads, experiments, CI tasks). They're your machines, but the extra
paranoia of zone isolation protects personal devices (`trusted`) — like
Windows desktops — from misconfiguration or compromise on the dev side.
Asymmetric access: `trusted` can reach `lab`, but not vice versa.

## Goals

1. Create a new VLAN and zone (`lab`, VLAN 21)
2. Move edith (calvard Incus container) from `trusted` to `lab`
3. Move trista (erebonia Incus VM) from `dmz` to `lab`
4. Merge `wg-vpn` into the `lab` zone (same trust level as dev environments)
5. Update OpenWrt router and switch to trunk the new VLAN

## Non-goals

- Changing the `ba-tunnel` WireGuard (langport external access — separate trust model)
- Moving any DMZ services (langport, oracion, creil, etc.) — they stay on vDMZ
- Headscale VPN (friends/game servers — separate concern, stays on vDMZ)

---

## VLAN Assignment

| Property | Value |
|----------|-------|
| Zone name | `lab` |
| VLAN ID | 21 |
| Bridge name | `brLAB` (router), `br21` (VM hosts) |
| IPv4 subnet | `10.97.21.0/24` |
| IPv6 subnet | `fdc6:55f2:0a5e:15::/64` |
| Gateway IPv4 | `10.97.21.1` |
| Gateway IPv6 | `fdc6:55f2:0a5e:15::1` |

VLAN 21 is unused — adjacent to trusted (VLAN 20), reflecting the semi-trusted
relationship. The numbering groups trust tiers: 10-11 infra, 20-21 user, 30-31
untrusted, 40-41 IoT/game, 100 DMZ.

---

## Phase 1: Network Registry

**File:** `lib/common/data/network.nix`

Add the `lab` zone and move edith + trista into it:

```nix
# Remove from trusted:
trusted = {
  vlanId = 20;
  hosts = {
    azoth = 50;
    # edith removed
  };
};

# Remove from dmz:
dmz = {
  vlanId = 100;
  hosts = {
    ardent = 31;
    # trista removed
    langport = 41;
    oracion = 52;
    creil = 53;
    monrain = 32;
    "saint-arkh" = 61;
  };
};

# Add new zone:
lab = {
  vlanId = 21;
  hosts = {
    edith = 42;   # Dev environment / task runner (calvard Incus container)
    trista = 51;  # SSH bastion / lab VM (erebonia Incus VM)
  };
};
```

Host IDs are carried over from their old zones. Since the VLAN changed, the
full IPs change (e.g., edith: `10.97.20.42` → `10.97.21.42`).

**New addresses:**

| Host | Old IPv4 | New IPv4 | Old IPv6 | New IPv6 |
|------|----------|----------|----------|----------|
| edith | `10.97.20.42` | `10.97.21.42` | `fdc6:55f2:0a5e:14::2a` | `fdc6:55f2:0a5e:15::2a` |
| trista | `10.97.100.51` | `10.97.21.51` | `fdc6:55f2:0a5e:64::33` | `fdc6:55f2:0a5e:15::33` |

---

## Phase 2: Router Zone & Topology

**File:** `hosts/thebeyond/router.nix`

### 2a. Add mkVlanBridge for VLAN 21

Add to the `vlanDefs` (alongside existing MGMT, INFRA, HOME, etc.):

```nix
(mkVlanBridge {
  name = "LAB";
  tag = 21;
  addresses = [lab.gateway4cidr lab.gateway6cidr];
  zone = "lab";
})
```

Where `lab` is derived from the network registry like the other zones.

### 2b. Define the lab zone

```nix
lab = {
  # Dev environments running untrusted code: reach infra services and DMZ,
  # internet for packages/updates, but no access to personal devices (trusted)
  icmpEcho = "enable";
  accessTo = ["management" "dmz" "external"];
  inputRules = [
    {
      verdict = "accept";
      comment = "Full router service access";
    }
  ];
};
```

**Access policy rationale:**
- `management` — reach basel (SSH certs), messeldam (Keycloak OIDC), phantasma
  (DNS), creil (Forgejo is on DMZ but management has other services)
- `dmz` — reach creil (Forgejo), oracion (media), langport (reverse proxy)
- `external` — internet for package downloads, git, etc.
- **NOT** `trusted` — asymmetric containment; a misconfigured or compromised
  dev env cannot reach personal devices (Windows desktop, wife's laptop, etc.)

### 2c. Merge wg-vpn into lab zone

Change the `wg-vpn` WireGuard device's zone from `vpn` to `lab`:

```nix
# In topology.devices."wg-vpn".network:
zone = "lab";  # was "vpn"
```

Remove the now-unused `vpn` zone definition.

The old `vpn` zone had `accessTo = ["management" "untrusted" "dmz"]`. The new
`lab` zone drops `untrusted` (no reason for dev envs to reach IoT/guest) and
adds `external` (internet access for packages). The VPN client (laptop) and
dev environments share the same trust level.

### 2d. Update trusted zone

The `trusted` zone currently has `accessTo = ["management" "trusted" "untrusted" "external"]`.
Add `"lab"` so devices on the home LAN can reach edith/trista:

```nix
trusted = {
  icmpEcho = "enable";
  accessTo = ["management" "trusted" "untrusted" "lab" "external"];
  # ...
};
```

### 2e. Review extraForwardRules

Check existing `extraForwardRules` for any rules referencing edith or trista
by their old IPs/zones. Update or remove as needed — zone-based `accessTo`
should handle most cases, reducing the need for per-host forward rules.

Also check the SSH port forward from wg-ba to trista — trista's IP changes,
so any DNAT rules referencing `10.97.100.51` need updating.

---

## Phase 3: VM Host Bridge Setup

### 3a. calvard (edith's parent)

**File:** `hosts/calvard/microvm/default.nix`

Add VLAN 21 bridge infrastructure. calvard currently has br11, br20, br100.
Since edith is the only guest on br20, br20 can be replaced with br21, or
both can coexist during transition.

```nix
# Add netdev for br21
netdevs."20-br21" = {
  netdevConfig.Kind = "bridge";
  netdevConfig.Name = "br21";
};
netdevs."20-enp88s0.21" = {
  netdevConfig.Kind = "vlan";
  netdevConfig.Name = "enp88s0.21";
  vlanConfig.Id = 21;
};

# Add VLAN to trunk
# In networks."20-enp88s0".vlan, add "enp88s0.21"

# Bridge rule (Incus guests use vm-21-* naming? No — Incus bridges directly)
# For Incus containers, the bridge rule matches the physical VLAN interface
networks."20-vm21-bridge" = {
  matchConfig.Name = ["enp88s0.21"];
  networkConfig.Bridge = "br21";
  networkConfig.DHCP = "no";
  networkConfig.LinkLocalAddressing = "no";
  networkConfig.IPv6PrivacyExtensions = "kernel";
};
networks."20-br21" = {
  matchConfig.Name = "br21";
  networkConfig.DHCP = "no";
  networkConfig.LinkLocalAddressing = "no";
  networkConfig.IPv6PrivacyExtensions = "kernel";
};
```

Remove br20 infrastructure if edith was the only consumer (azoth is a
Raspberry Pi with its own network config, not a calvard guest). Check
whether any other calvard guests use br20.

### 3b. erebonia (trista's parent)

**File:** `hosts/erebonia/microvm/default.nix`

Add VLAN 21 bridge infrastructure. erebonia currently has br11, br20, br100.

```nix
# Add netdev for br21
netdevs."20-br21" = {
  netdevConfig.Kind = "bridge";
  netdevConfig.Name = "br21";
};
netdevs."20-eno1.21" = {
  netdevConfig.Kind = "vlan";
  netdevConfig.Name = "eno1.21";
  vlanConfig.Id = 21;
};

# Add VLAN to trunk
# In networks."20-eno1".vlan, add "eno1.21"

# Bridge rule
networks."20-vm21-bridge" = {
  matchConfig.Name = ["eno1.21" "vm-21-*"];
  networkConfig.Bridge = "br21";
  networkConfig.DHCP = "no";
  networkConfig.LinkLocalAddressing = "no";
  networkConfig.IPv6PrivacyExtensions = "kernel";
};
networks."20-br21" = {
  matchConfig.Name = "br21";
  networkConfig.DHCP = "no";
  networkConfig.LinkLocalAddressing = "no";
  networkConfig.IPv6PrivacyExtensions = "kernel";
};
```

Remove br100 infrastructure if trista was the only consumer on erebonia.
Check whether saint-arkh or other erebonia guests use br100.

### 3c. Update erebonia input firewall

**File:** `hosts/erebonia/microvm/default.nix` (line 136)

Currently allows SSH from `trusted` subnet. If needed, also allow from `lab`:

```nix
networking.firewall.extraInputRules = ''
  ip saddr { ${zone.gateway4}, ${net.networks.trusted.subnet4}, ${net.networks.lab.subnet4} } tcp dport 22 accept
  ip6 saddr { ${zone.gateway6}, ${net.networks.trusted.subnet6}, ${net.networks.lab.subnet6} } tcp dport 22 accept
  tcp dport 22 drop
'';
```

---

## Phase 4: Guest Configuration Updates

### 4a. edith

**File:** `hosts/calvard/incus/guests/edith/default.nix`

- Change `bridge = "br20"` → `bridge = "br21"`
- Update static network config: IPs, gateway, DNS all change with the new VLAN
- The network registry handles address derivation — update `forHost "edith"`
  references (should auto-resolve after Phase 1)

### 4b. trista

**File:** `hosts/erebonia/incus/guests/trista/default.nix`

- Change `bridge = "br100"` → `bridge = "br21"`
- Update static network config: IPs, gateway, DNS
- Same registry-driven update as edith

### 4c. Trista egress filtering — DEFERRED

Trista egress filtering deferred to a follow-up. Zone-based firewall rules
(lab zone `accessTo`) provide sufficient containment for now.

---

## Phase 5: OpenWrt Updates

Both OpenWrt devices need VLAN 21 added to their trunk ports.

### 5a. OpenWrt switch (arseille)

**File:** `lib/common/data/openwrt.nix` — `switchVlans`

Add VLAN 21 to the switch VLAN table:

```nix
switchVlans = {
  # ... existing VLANs ...
  LAB = { tag = 21; };
};
```

No access ports needed — lab devices are VMs on trunked VM hosts, not
physical devices plugged into switch ports.

### 5b. OpenWrt router (temporary router)

**File:** `lib/common/data/openwrt.nix` — `routerVlans`

Add VLAN 21 to the router VLAN table:

```nix
routerVlans = {
  # ... existing VLANs ...
  LAB = { tag = 21; };
};
```

### 5c. Deployment

Build and deploy updated configs to both devices:

```bash
# Build configs
nix build .#openwrtConfigurations.arseille
nix build .#openwrtConfigurations.<router-name>

# Deploy (or use openwrt-deploy)
nix run .#openwrt-deploy -- arseille <switch-ip>
nix run .#openwrt-deploy -- <router-name> <router-ip>
```

**Important:** OpenWrt must be updated *before* the NixOS hosts, otherwise
the new VLAN 21 frames will be dropped by the switch/router as untagged.

---

## Phase 6: DNS & Monitoring Updates

### 6a. DNS records

edith and trista's DNS records update automatically via `mkUnboundLocalData`
and `mkExtraHosts` once the network registry is updated (Phase 1). Verify
that phantasma's Unbound config references these hosts.

### 6b. Prometheus scrape targets

If tharbad scrapes edith or trista, update target addresses. The management
zone's `accessTo` doesn't include `lab`, so a cross-zone forward rule may
be needed for scraping:

```nix
# tharbad (management) → lab zone exporter ports
{ iifname = "brINFRA"; oifname = "brLAB";
  ip.saddr = tharbad.ipv4; tcp.dport = 9100;
  verdict = "accept"; comment = "tharbad -> lab (node_exporter)"; }
```

### 6c. Promtail log shipping

Lab zone hosts need to reach tharbad:3100 (Loki). Add a cross-zone forward
rule if not covered by `accessTo`:

The `lab` zone has `accessTo = ["management" ...]`, so lab → management
traffic is already allowed. No extra forward rule needed for Loki.

### 6d. Forgejo SSH access

If the `wg-ba` SSH port forward currently points to trista at `10.97.100.51`,
update the DNAT destination to `10.97.21.51`.

---

## Deployment Order

1. **OpenWrt switch + router** — add VLAN 21 to trunk ports (frames must be
   accepted before NixOS hosts can use them)
2. **Router (thebeyond)** — add mkVlanBridge, zone definition, update wg-vpn
   zone, update trusted accessTo
3. **VM hosts (calvard, erebonia)** — add br21 bridge infrastructure
4. **Guests (edith, trista)** — update bridge, IPs (guests will be
   briefly unreachable during the switchover)
5. **Verify** — ping, DNS resolution, SSH cert flow, VPN → edith

---

## Files Modified

| File | Change |
|------|--------|
| `lib/common/data/network.nix` | Add `lab` zone, move edith + trista |
| `lib/common/data/openwrt.nix` | Add VLAN 21 to switchVlans + routerVlans |
| `hosts/thebeyond/router.nix` | Add mkVlanBridge, lab zone, update vpn→lab, update trusted accessTo |
| `hosts/calvard/microvm/default.nix` | Add br21 bridge infrastructure |
| `hosts/erebonia/microvm/default.nix` | Add br21 bridge infrastructure |
| `hosts/calvard/incus/guests/edith/default.nix` | Update bridge + network config |
| `hosts/erebonia/incus/guests/trista/default.nix` | Update bridge + network config |

## Testing

- Existing integration tests should still pass (zone refactor snapshot tests
  will need golden file updates for the new zone)
- Verify edith reachable from trusted zone (home WiFi)
- Verify edith reachable from wg-vpn (remote VPN)
- Verify trista SSH bastion path (wg-ba → trista)
- Verify lab zone cannot reach trusted zone (blast-radius test)
- Verify DNS records updated (edith.internal, trista.internal)

## Resolved Questions

1. **saint-arkh stays on DMZ.** CI runner tied to creil (Forgejo Actions) —
   DMZ is the right zone. Uses `vm-100-s-arkh` on erebonia br100.
2. **Trista keeps current role** (SSH bastion + lab VM) with updated IP.
3. **br20 removed from calvard.** edith was the only guest; azoth is a
   standalone Pi. Replace br20 with br21.
4. **br100 stays on erebonia.** saint-arkh uses it. br20 on erebonia has
   no consumers — remove it, add br21.
5. **Trista egress filtering deferred** to follow-up. Zone-based rules suffice.
6. **lab→management access kept broad** as a jump-box path for pushing fixes.
   May be tightened later once management access patterns are clearer.
