# vLAB Zone Implementation Plan

## Context

Create a dedicated `lab` zone for development environments where untrusted code
runs (edith, future dev environments). The laptop VPN (`wg-vpn`) needs
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
3. Merge `wg-vpn` into the `lab` zone (same trust level as dev environments)
4. Update OpenWrt router and switch to trunk the new VLAN
5. Clean up ba-tunnel rules (mesh peer → trista SSH only)

## Non-goals

- Moving trista — stays on DMZ (serves wg-ba mesh peer relationship)
- Moving any other DMZ services (langport, oracion, creil, etc.)
- Headscale VPN (friends/game servers — separate concern, stays on vDMZ)

---

## VLAN Assignment

| Property     | Value                               |
| ------------ | ----------------------------------- |
| Zone name    | `lab`                               |
| VLAN ID      | 21                                  |
| Bridge name  | `brLAB` (router), `br21` (VM hosts) |
| IPv4 subnet  | `10.97.21.0/24`                     |
| IPv6 subnet  | `fdc6:55f2:0a5e:15::/64`            |
| Gateway IPv4 | `10.97.21.1`                        |
| Gateway IPv6 | `fdc6:55f2:0a5e:15::1`              |

VLAN 21 is unused — adjacent to trusted (VLAN 20), reflecting the semi-trusted
relationship. The numbering groups trust tiers: 10-11 infra, 20-21 user, 30-31
untrusted, 40-41 IoT/game, 100 DMZ.

---

## Phase 1: Network Registry — DONE

**File:** `lib/common/data/network.nix`

Move edith from `trusted` to new `lab` zone. Trista stays in `dmz`.

```nix
# Remove from trusted:
trusted = {
  vlanId = 20;
  hosts = {
    azoth = 50;
    # edith removed
  };
};

# Add new zone:
lab = {
  vlanId = 21;
  hosts = {
    edith = 42;   # Dev environment / task runner (calvard Incus container)
  };
};
```

Host ID carried over from old zone. Since the VLAN changed, the full IP changes.

**New addresses:**

| Host  | Old IPv4      | New IPv4      | Old IPv6                | New IPv6                |
| ----- | ------------- | ------------- | ----------------------- | ----------------------- |
| edith | `10.97.20.42` | `10.97.21.42` | `fdc6:55f2:0a5e:14::2a` | `fdc6:55f2:0a5e:15::2a` |

---

## Phase 2: Router Zone & Topology — DONE

**File:** `hosts/thebeyond/router.nix`

### 2a. Add mkVlanBridge for VLAN 21

```nix
(mkVlanBridge {
  name = "LAB";
  tag = 21;
  addresses = ["10.97.21.1/24"];
  zone = "lab";
})
```

### 2b. Define the lab zone

```nix
lab = {
  icmpEcho = "enable";
  accessTo = ["management" "lab" "dmz" "external"];
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
  (DNS), and serves as jump-box path for pushing fixes to infrastructure
- `lab` — self-referential: required for routed intra-zone traffic (wg-vpn
  subnet 10.100.10.0/24 → edith on 10.97.21.0/24 crosses interfaces, hits
  the forward chain, and needs an explicit lab→lab allow rule)
- `dmz` — reach creil (Forgejo), oracion (media), langport (reverse proxy)
- `external` — internet for package downloads, git, etc.
- **NOT** `trusted` — asymmetric containment; a misconfigured or compromised
  dev env cannot reach personal devices (Windows desktop, wife's laptop, etc.)

### 2c. Merge wg-vpn into lab zone

Changed `wg-vpn` WireGuard device zone from `vpn` to `lab`.
Removed the now-unused `vpn` zone definition.

### 2d. Update trusted zone

Added `"lab"` to trusted zone's `accessTo` so home LAN devices can reach edith.

### 2e. Clean up ba-tunnel

ba-tunnel is a mesh peer tunnel — only gives access to trista SSH.
Tightened rules to trista SSH only (was overly broad). Removed extraneous
dmz→ba-tunnel forward rules.

```nix
ba-tunnel = {
  icmpEcho = "disable";
  accessTo = [];
  forwardRules.dmz = [
    { ip.daddr = trista.ipv4; tcp.dport = 22; verdict = "accept"; comment = "wg-ba -> trista SSH (v4)"; }
    { ip6.daddr = trista.ipv6; tcp.dport = 22; verdict = "accept"; comment = "wg-ba -> trista SSH (v6)"; }
  ];
  inputRules = [];
};
```

### 2f. Remove opt2 device

opt2 was squatting on 10.97.21.0/24 (subnetId=21) with zone "trusted".
Removed to avoid IP/subnet collision with brLAB.

---

## Phase 3: VM Host Bridge Setup — DONE

### 3a. calvard (edith's parent)

**File:** `hosts/calvard/microvm/default.nix`

Replaced br20/enp88s0.20 with br21/enp88s0.21. edith was the only br20
consumer (azoth is a standalone Raspberry Pi).

### 3b. erebonia

**File:** `hosts/erebonia/microvm/default.nix`

Replaced br20/eno1.20 with br21/eno1.21. No current lab guests on erebonia
but infrastructure is ready for future use. br100 kept (saint-arkh uses it).

---

## Phase 4: Guest Configuration Updates — DONE

### 4a. edith

**File:** `hosts/calvard/incus/guests/edith/default.nix`

- Changed `bridge = "br20"` → `bridge = "br21"`
- Updated static network config: IPs to `10.97.21.42/24` and
  `fdc6:55f2:0a5e:15::2a/64`, gateways and DNS to VLAN 21

### 4b. calvard SSH target

**File:** `hosts/calvard/default.nix`

Updated edith SSH hostname from `10.97.20.42` to `10.97.21.42`.

---

## Phase 5: OpenWrt Updates — DONE

**File:** `lib/common/data/openwrt.nix`

Added `LAB = {tag = 21;};` to both `switchVlans` and `routerVlans`.
OpenWrt devices updated and deployed before NixOS changes.

---

## Phase 6: DNS & Monitoring Updates

### 6a. DNS records

edith's DNS records update automatically via `mkUnboundLocalData`
and `mkExtraHosts` once the network registry is updated (Phase 1). Verify
that phantasma's Unbound config references edith.

### 6b. Prometheus scrape targets

If tharbad scrapes edith, update target addresses. The management
zone's `accessTo` doesn't include `lab`, so a cross-zone forward rule may
be needed for scraping.

### 6c. Promtail log shipping

Lab zone hosts need to reach tharbad:3100 (Loki). The `lab` zone has
`accessTo = ["management" ...]`, so lab → management traffic is already
allowed. No extra forward rule needed.

---

## Deployment Order

1. **OpenWrt switch + router** — add VLAN 21 to trunk ports ✅
2. **Router (thebeyond)** — add mkVlanBridge, zone definition, update wg-vpn
   zone, update trusted accessTo, clean up ba-tunnel ✅
3. **VM hosts (calvard, erebonia)** — add br21 bridge infrastructure ✅
4. **Guest (edith)** — update bridge, IPs ✅
5. **Verify** — ping, DNS resolution, SSH cert flow, VPN → edith

---

## Files Modified

| File                                           | Change                                           |
| ---------------------------------------------- | ------------------------------------------------ |
| `lib/common/data/network.nix`                  | Add `lab` zone, move edith from trusted          |
| `lib/common/data/openwrt.nix`                  | Add VLAN 21 to switchVlans + routerVlans         |
| `hosts/thebeyond/router.nix`                   | Add brLAB, lab zone, vpn→lab, trusted, ba-tunnel |
| `hosts/calvard/microvm/default.nix`            | Replace br20 with br21                           |
| `hosts/erebonia/microvm/default.nix`           | Replace br20 with br21                           |
| `hosts/calvard/incus/guests/edith/default.nix` | Update bridge + network config                   |
| `hosts/calvard/default.nix`                    | Update edith SSH target IP                       |

## Testing

- Existing integration tests should still pass (zone refactor snapshot tests
  will need golden file updates for the new zone)
- Verify edith reachable from trusted zone (home WiFi)
- Verify edith reachable from wg-vpn (remote VPN)
- Verify trista SSH bastion path (wg-ba → trista) still works (unchanged)
- Verify lab zone cannot reach trusted zone (blast-radius test)
- Verify DNS records updated (edith.internal)

## Resolved Questions

1. **saint-arkh stays on DMZ.** CI runner tied to creil (Forgejo Actions) —
   DMZ is the right zone. Uses `vm-100-s-arkh` on erebonia br100.
2. **Trista stays on DMZ.** Serves wg-ba mesh peer relationship. Not a lab VM.
3. **br20 removed from calvard.** edith was the only guest; azoth is a
   standalone Pi. Replace br20 with br21.
4. **br100 stays on erebonia.** saint-arkh uses it. br20 on erebonia has
   no consumers — remove it, add br21.
5. **Trista egress filtering deferred** to follow-up. Zone-based rules suffice.
6. **lab→management access kept broad** as a jump-box path for pushing fixes.
   May be tightened later once management access patterns are clearer.
7. **opt2 removed.** Was squatting on 10.97.21.0/24 — conflicted with brLAB.
8. **ba-tunnel tightened.** Mesh peer gets trista SSH only, no blanket access.
