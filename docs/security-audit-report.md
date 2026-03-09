# Security Audit Report: Router6 Network Infrastructure

**Audit Date:** 2026-03-09
**Auditor:** Claude Opus 4.6 (AI-assisted security review)
**Scope:** router6 NixOS module, thebeyond host configuration, generated system image
**Overall Status:** PASS with recommendations

---

## Executive Summary

This audit examines a NixOS-based router infrastructure consisting of a custom firewall/routing DSL ("router6"), its deployment on the "thebeyond" host, and the generated system configuration. The system implements a **zone-based, default-deny firewall** with VLAN segmentation, WireGuard VPN, DNS interception, and full dual-stack IPv4/IPv6 support.

**The system is well-designed from a security perspective.** The architecture follows defense-in-depth principles: default-drop firewall policies, strict zone isolation, VLAN network segmentation, DNS interception to prevent bypass, LUKS disk encryption, impermanent root filesystem, and hardened SSH. The Nix-based approach provides reproducibility and auditability that is superior to imperative router configurations.

**Key strengths:**
- Default-deny firewall with stealth mode (silent drop, no reject responses)
- Comprehensive build-time validation (35+ assertions catch misconfigurations before deployment)
- Extensive test coverage (22+ checks including VM integration tests)
- DNS interception prevents IoT/smart device DNS bypass
- Secrets management via sops-nix with age encryption
- Impermanent root filesystem reduces persistent compromise surface

**Areas for improvement:**
- Output chain is `policy accept` — no egress filtering on the router itself
- WireGuard public keys are hardcoded in Nix (low risk but worth noting)
- No `ct state invalid drop` rule in the firewall
- kresd listens on more interfaces than strictly necessary (network zone gets DNS despite inputRules only allowing NTP)
- DHCP snooping/ARP inspection not implemented (common in enterprise, uncommon in home routers)

---

## Module 1: Router6 DSL

**File:** `modules/router6/default.nix` (2,223 lines)
**Supporting libraries:** `lib/nftables.nix` (257 lines), `lib/common/default.nix` (125 lines)

### Security Assessment: STRONG

The router6 module is a well-architected, security-first router DSL. Its design philosophy — topology-driven configuration with derived firewall rules — reduces the surface area for human error compared to hand-written nftables rules.

### Key Security Features

#### 1. Default-Deny Firewall (Critical — IMPLEMENTED)
```
chain input  { ... policy drop; }
chain forward { ... policy drop; }
```
Both input and forward chains default to `drop`. This is the gold standard for firewall design — traffic must be explicitly permitted. The `drop` verdict (not `reject`) implements stealth mode, preventing information leakage about the router's existence to external attackers.

#### 2. Zone-Based Access Control (Critical — IMPLEMENTED)
Zones are the primary abstraction for firewall policy. Each zone defines:
- `icmpEcho`: Granular ICMP control (enable/disable/ipv4-only/ipv6-only)
- `accessTo`: Blanket forward-chain access to other zones
- `forwardRules`: Per-destination-zone filtered forwarding
- `inputRules`: Services accessible from this zone on the router itself

The zone model enforces **mutual exclusivity** between `accessTo` and `forwardRules` per destination zone, preventing conflicting policies. Zone names are validated against the `types.enum` of defined zones, making typos a build-time error.

#### 3. Build-Time Assertions (Critical — IMPLEMENTED)
35+ assertions validate configuration before deployment:
- DHCPv6 server cannot be on a DHCP client interface (prevents upstream RA leakage)
- `inputRules` cannot contain `iifname` (auto-set from zone, prevents bypass)
- `forwardRules` cannot contain `iifname`/`oifname` (auto-set, prevents bypass)
- `forwardRules` keys must reference valid zones
- `accessTo` and `forwardRules` cannot overlap per destination
- WireGuard `openFirewall` requires `port` to be set
- Bond/bridge/batman member validation (existence, correct kind)
- Cross-kind membership conflict detection (same interface in batman + bridge)
- PD subnet requires PD source
- DynDNS domain/domainFile mutual exclusivity

These assertions are **security-critical** — they catch misconfiguration at build time, not at runtime.

#### 4. Connection Tracking (Important — IMPLEMENTED)
```
ct state established,related accept
```
Stateful inspection is the first rule in both input and forward chains, ensuring return traffic for established connections is always permitted while new inbound connections are subject to zone policies.

#### 5. Essential ICMP Handling (Important — CORRECTLY IMPLEMENTED)
The module correctly distinguishes between:
- **Essential ICMP** (always allowed): destination-unreachable, packet-too-big, time-exceeded, parameter-problem, NDP messages. These are required for correct network operation (PMTUD, neighbor discovery).
- **Echo ICMP** (zone-controlled): echo-request/echo-reply are gated by the per-zone `icmpEcho` setting.

This is the correct approach — blocking essential ICMP breaks PMTUD and IPv6 entirely, while echo can be selectively disabled for security.

#### 6. TCP MSS Clamping (Important — IMPLEMENTED)
```
tcp flags syn tcp option maxseg size set rt mtu
```
Automatically clamps TCP MSS to the path MTU in the forward chain, preventing fragmentation issues across VPN tunnels and mismatched MTU paths.

#### 7. DHCPv6 Client Rule (Important — CORRECTLY IMPLEMENTED)
```
iifname { "wan" } udp dport 546 accept
```
DHCPv6 uses regular UDP sockets (unlike DHCPv4 which uses raw sockets), so it IS subject to nftables filtering. The module correctly adds an explicit accept rule for DHCPv6 client responses on DHCP interfaces, with a clear comment explaining why conntrack can't handle this (multicast Solicit → unicast Reply mismatch).

#### 8. Sysctl Hardening (Important — IMPLEMENTED)
- `net.ipv4.conf.all.forwarding = true` / `net.ipv6.conf.all.forwarding = true` — routing enabled
- `net.ipv4.conf.default.rp_filter = 1` / `net.ipv4.conf.all.rp_filter = 1` — strict reverse path filtering (prevents IP spoofing)
- `net.ipv6.conf.all.accept_ra = 0` / `net.ipv6.conf.default.accept_ra = 0` — globally disable RA acceptance (prevents rogue RA attacks)
- Per-interface `accept_ra = 2` only on DHCP/WAN interfaces — correct behavior, allows RA from ISP while rejecting rogue RAs on LAN

#### 9. Nftables DSL Safety (Important — IMPLEMENTED)
The `lib/nftables.nix` DSL provides:
- Automatic quoting of interface names (prevents injection)
- Type-safe rendering (ints, strings, lists, negation, vmaps handled correctly)
- Raw string escape hatch for edge cases
- Structured rule composition that is auditable

### Security Concerns

#### 1. Output Chain Policy Accept (MEDIUM)
```
chain output { type filter hook output priority filter; policy accept; }
```
The router's output chain has `policy accept`, meaning a compromised router process can communicate freely with any destination. While the `mkEgressFilter` utility exists in `lib/common/default.nix` for use on other hosts, it is **not applied to the router itself**.

**Recommendation:** Consider adding egress filtering on the router's output chain, at minimum restricting outbound traffic to expected protocols (DNS, NTP, DHCP, SSH, WireGuard, HTTP/S for updates). This limits the blast radius of a compromised router process.

#### 2. No `ct state invalid drop` (LOW-MEDIUM)
The firewall does not explicitly drop `ct state invalid` packets. While these would be caught by the default drop policy if they don't match any accept rule, invalid packets could match an `established,related` rule due to conntrack state confusion.

**Recommendation:** Add `ct state invalid drop` immediately after the `ct state established,related accept` rule in both input and forward chains.

#### 3. No Rate Limiting on Accept Rules (LOW)
The DSL supports `limit rate` syntax, but no rate limiting is applied to any accept rules in the base firewall. This means an attacker on a trusted zone could flood the router with accepted traffic.

**Recommendation:** Consider rate limiting ICMP echo and DNS/DHCP accept rules to prevent resource exhaustion.

#### 4. Raw String Escape Hatch (LOW)
The nftables DSL accepts raw strings alongside structured rules. While this is a useful escape hatch, raw strings bypass the structural validation of the DSL. No assertions validate raw string rules.

**Recommendation:** Document the security implications of raw string rules. Consider adding a `dangerouslyAllowRawRules` flag that must be explicitly set.

#### 5. VLAN Tag Range Not Validated (LOW)
VLAN tags are `types.int` without range validation (should be 1-4094). While out-of-range values would fail at the systemd-networkd level, catching this at Nix eval time would be better.

**Recommendation:** Change the VLAN tag type to `types.ints.between 1 4094`.

### Test Coverage Assessment: STRONG

The router6 module has excellent test coverage across two categories:

**Pure Nix evaluation tests (12 test files):**
- `nftables.nix`: 65+ test cases for the DSL renderer
- `router6-assertions.nix`: 8 failure scenarios for config validation
- `router6-firewall-properties.nix`: DHCPv6 client rules, masquerade, NDP
- `router6-zone-system.nix`: Forward rules, multi-iface zones, icmpEcho variants
- `router6-dhcp-config.nix`: Subnet IDs, pools, reservations
- `router6-dhcpv6.nix`: RA flags, pool allocation
- `router6-dnat-properties.nix`: DNAT rule generation
- `router6-kresd-config.nix`: DNS upstream/fallback/DNSSEC
- `router6-sysctl-properties.nix`: Forwarding, rp_filter, RA acceptance
- `router6-wireguard-config.nix`: Netdev/network/firewall generation
- `router6-dyndns-config.nix`: Service/timer/script generation
- `router6-pppoe-config.nix`: PPPoE type support

**VM integration tests (11 test files):**
- `router6-firewall.nix`: Stealth mode validation (9 tests)
- `router6-firewall-zones.nix`: Multi-zone access control (28 tests)
- `router6-ipv6.nix`: Full IPv6 stack (SLAAC, RA, kresd)
- `router6-dhcpv6.nix`: Stateful/stateless DHCPv6
- `router6-wan-dhcp.nix`: WAN DHCP client + NAT
- `router6-wan-ipv6-pd.nix`: IPv6 prefix delegation end-to-end
- `router6-bond-bridge.nix`: Link aggregation + bridging
- `router6-device-vlans.nix`: VLAN stacking
- `router6-dnat.nix`: Port forwarding end-to-end
- `router6-extra-rules.nix`: Escape hatch rules
- `egress-filter.nix`: Output chain filtering

**Testing gaps:**
- No test for `ct state invalid` handling
- No test for WireGuard end-to-end connectivity
- No negative test for DNS interception (verifying bypass is actually caught)
- No performance/stress testing
- No test for PPPoE end-to-end (only config generation)

---

## Module 2: Thebeyond Host Configuration

**Files:** `hosts/thebeyond/default.nix`, `hosts/thebeyond/router.nix`, `hosts/thebeyond/sops.nix`, `hosts/thebeyond/impermanence.nix`

### Security Assessment: STRONG

The thebeyond host is a well-segmented router with 8 VLANs, 6 firewall zones, 2 WireGuard tunnels, DNS interception, and LUKS encryption.

### Key Security Features

#### 1. Network Segmentation (Critical — WELL DESIGNED)

| VLAN | Name  | Zone        | Purpose              | Internet | Lateral Movement |
|------|-------|-------------|----------------------|----------|------------------|
| 10   | MGMT  | network     | APs, switches        | No       | No               |
| 11   | INFRA | management  | NAS, VMs, DNS        | Filtered | Full internal    |
| 20   | HOME  | trusted     | User devices         | Yes      | Full internal    |
| 21   | -     | trusted     | Direct test port     | Yes      | Full internal    |
| 30   | GUEST | untrusted   | Guest devices        | Yes      | No               |
| 31   | ADU   | untrusted   | Separate dwelling    | Yes      | No               |
| 40   | IOT   | untrusted   | Smart home devices   | Yes      | No               |
| 41   | GAME  | untrusted   | Gaming devices       | Yes      | No               |
| 100  | DMZ   | untrusted   | Exposed services     | Yes      | No               |

Zone policy analysis:
- **external** (WAN): No ICMP echo, no input rules, no access to anything — fully isolated
- **network**: ICMP echo allowed, NTP only — APs and switches are heavily restricted
- **management**: Full router access, filtered egress (DNS/HTTP/HTTPS/NTP only) — infrastructure gets controlled internet
- **trusted**: Full router access, full internet + internal access — user devices are fully trusted
- **untrusted**: DNS/DHCP/DHCPv6 only, internet only, no lateral movement — IoT/guest isolation
- **vpn**: Full router access, access to management + untrusted zones — VPN clients can reach infra but not home LAN
- **isolated**: No ICMP, no input rules, no access — complete isolation (used for wg-ba)

This is a **well-thought-out zone hierarchy** that correctly implements the principle of least privilege.

#### 2. DNS Interception (Critical — IMPLEMENTED)
```nft
ip saddr != { phantasma, phantasma-legacy } ip daddr != { router, router-legacy, phantasma, phantasma-legacy }
  udp dport 53 dnat to router:53
```
DNS interception catches devices (Google Home, Nest, etc.) that hardcode DNS servers (e.g., 8.8.8.8), redirecting all port-53 traffic to the router's resolver. Phantasma (the internal DNS server) is correctly excluded so its recursive queries work.

Both IPv4 and IPv6 DNS interception are implemented, and both UDP and TCP are covered.

#### 3. LUKS Disk Encryption (Critical — IMPLEMENTED)
- Root partition encrypted with LUKS (`cryptroot`)
- Key stored on ESP (`/boot/secrets/disk.key`)
- ESP mounted in initrd, keyfile used, ESP unmounted before normal boot
- `/boot/secrets` directory permissions set to 700

#### 4. Impermanent Root Filesystem (Important — IMPLEMENTED)
The root filesystem is ephemeral (tmpfs), with only explicitly declared state persisted:
- `/var/lib/private/kea` — DHCP leases
- `/var/lib/knot-resolver` — DNS cache
- SSH host keys (via sops-nix)

This significantly reduces the attack surface — even if an attacker gains root, their changes are lost on reboot.

#### 5. Hardened SSH (Important — IMPLEMENTED)
Evaluated SSH settings show:
- `PasswordAuthentication = false` — key-only authentication
- `PermitRootLogin = "prohibit-password"` — root key-only
- `KbdInteractiveAuthentication = false` — no keyboard-interactive
- `X11Forwarding = false` — no X11 forwarding
- Post-quantum key exchange: `mlkem768x25519-sha256`, `sntrup761x25519-sha512`
- Strong ciphers: `chacha20-poly1305`, `aes256-gcm`, `aes128-gcm`
- Strong MACs: `hmac-sha2-512-etm`, `hmac-sha2-256-etm`, `umac-128-etm`
- `StrictModes = true`

This is an excellent SSH configuration with post-quantum cryptography support.

#### 6. Secrets Management (Important — IMPLEMENTED)
- sops-nix with age encryption
- WireGuard private keys decrypted to `/run/secrets/` with mode 0440
- WireGuard keys owned by `systemd-network` group
- DynDNS password and domain stored as secrets

#### 7. WireGuard VPN (Important — IMPLEMENTED)
Two WireGuard tunnels:
- **wg-ba** (port 38506): Isolated zone, BA tunnel with SSH port forward to ordis. Masquerade on both directions. Only accepts traffic from a single peer.
- **wg-vpn** (port 59362): VPN zone for mobile devices, 2 peers with tight `/32` and `/128` allowedIPs.

Both are correctly configured with:
- `required = false` — don't block boot if tunnel is down
- `openFirewall = true` — firewall ports opened automatically
- Tight `allowedIPs` per peer (no `0.0.0.0/0` wildcards)

#### 8. Inter-Zone Forward Rules (Important — CORRECTLY SCOPED)
The `extraForwardRules` implement precise cross-zone access for specific services:
- DMZ → wg-ba: Full access (ordis is behind VPN)
- wg-ba → ordis: IP-restricted (IPv4 + IPv6)
- ordis → roer: HTTPS only (OIDC token exchange)
- DMZ → legram: HTTPS only (ACME certificates)
- DMZ → ymir: Port 3100 only (Loki log push)

Each rule specifies source interface, destination IP, and destination port — no overly broad rules.

### Security Concerns

#### 1. SSH Port Not Firewall-Restricted (MEDIUM)
The SSH service is enabled but there is no explicit inputRule restricting SSH access. The `management` and `trusted` zones have blanket `accept` inputRules, meaning SSH is accessible from INFRA, HOME, and VPN zones. This is likely intentional but worth documenting.

**Recommendation:** Consider adding an explicit SSH-only inputRule for the VPN zone instead of blanket accept, since remote VPN users likely only need SSH and DNS.

#### 2. Prometheus Node Exporter Exposed (LOW-MEDIUM)
```nix
services.prometheus.exporters.node = {
  enable = true;
  port = 9100;
};
```
The node exporter is bound to all interfaces by default. Combined with blanket accept rules on management/trusted/vpn zones, this means system metrics are accessible from HOME, INFRA, and VPN. System metrics can leak sensitive information (filesystem paths, network connections, process names).

**Recommendation:** Bind the node exporter to the INFRA interface only, or add firewall rules restricting port 9100 to the monitoring host.

#### 3. Chrony NTP ACLs Use Legacy Subnets (LOW)
```nix
allow ${net.networks.network.subnet4}
allow ${net.networks.network.subnet4Legacy}
```
The Chrony NTP server allows both the new `10.97.x.x` and legacy `10.0.x.x` subnets. This is presumably for migration compatibility but should be cleaned up post-migration.

#### 4. kresd Listens on Network Zone Interfaces (LOW)
kresd listens on brMGMT (network zone), but the network zone's inputRules only allow NTP (UDP 123). DNS traffic from the network zone will hit kresd's listener but be dropped by the firewall. This is not a vulnerability (the firewall is authoritative), but the kresd listener is unnecessary.

**Recommendation:** Align kresd's listen interfaces with zones that actually permit DNS in their inputRules.

#### 5. WireGuard Public Keys in Nix Store (LOW)
WireGuard public keys are stored directly in `router.nix`. While public keys are not secret, they are visible in the Nix store, which is world-readable. This is standard practice and acceptable.

---

## Module 3: Generated System Configuration

### Security Assessment: STRONG

The generated nftables ruleset, systemd-networkd configuration, and service configs were evaluated directly from the NixOS configuration.

### Key Security Features

#### 1. Firewall Ruleset Analysis

**Input chain** (verified from generated output):
```
policy drop
├── ct state established,related accept
├── iifname "lo" accept
├── Essential ICMP (dest-unreach, pkt-too-big, time-exceeded, param-problem)
├── NDP (router-solicit/advert, neighbor-solicit/advert)
├── DHCPv6 client on wan (udp 546)
├── Per-zone ICMP echo rules
├── Per-zone inputRules
└── WireGuard ports (38506, 59362)
```

**Forward chain** (verified):
```
policy drop
├── ct state established,related accept
├── TCP MSS clamping
├── management → management, trusted, untrusted (accept)
├── management → external (DNS/HTTP/HTTPS/NTP only)
├── trusted → management, trusted, untrusted, external (accept)
├── untrusted → external (accept)
├── vpn → management, untrusted (accept)
├── DNAT forward accept (SSH to ordis)
└── Extra forward rules (DMZ↔wg-ba, DMZ→INFRA services)
```

**NAT tables** (verified):
- IPv4 masquerade on WAN only
- DNAT: SSH on wg-ba → ordis:22
- DNS interception: all port-53 traffic → router (excluding phantasma)
- WireGuard masquerade on wg-ba
- IPv6: DNS interception only, no masquerade (correct — no NAT66)

**Assessment:** The generated ruleset correctly implements the configured zone policies with no unexpected rules.

#### 2. Sysctl Verification

From the evaluated configuration:
| Setting | Value | Assessment |
|---------|-------|------------|
| `net.ipv4.conf.all.forwarding` | `true` | Required for routing |
| `net.ipv6.conf.all.forwarding` | `true` | Required for routing |
| `net.ipv4.conf.all.rp_filter` | `1` | Strict reverse path — prevents spoofing |
| `net.ipv4.conf.default.rp_filter` | `1` | Default strict reverse path |
| `net.ipv6.conf.all.accept_ra` | `0` | Globally disabled — prevents rogue RAs |
| `net.ipv6.conf.default.accept_ra` | `0` | Default disabled |
| `net.ipv6.conf.wan.accept_ra` | `2` | WAN only — correct for DHCP/PD |
| `kernel.kptr_restrict` | `1` | Hides kernel pointers — good |
| `net.ipv6.conf.default.use_tempaddr` | `"2"` | IPv6 privacy addresses — good |

All sysctl values are correct and well-configured.

#### 3. kresd DNS Configuration

**Listen addresses** (verified): Listens on localhost + all VLAN interfaces (IPv4 + IPv6). 22 listen addresses total.

**DNS policy**: Primary upstream (phantasma) with DHCP fallback. Local domain (`internal`) blocked from external resolution via `policy.suffix(policy.DENY)`. DNSSEC enabled.

**Assessment:** kresd configuration is correct. The DHCP fallback mechanism reads DNS servers from systemd lease files (trusted source), and the local domain deny policy prevents internal hostnames from leaking to external resolvers.

#### 4. Kea DHCP Configuration

**DHCP4** (verified): 8 subnets, all with correct router/DNS options pointing to the router's IP. Pool range `.100-.200` per subnet. Raw socket mode (`dhcp-socket-type = "raw"`) — correct for DHCP relay scenarios and bypasses firewall correctly.

**Assessment:** DHCP configuration is correct and well-scoped.

#### 5. Network Interface Security

- Physical interfaces identified by MAC address (prevents interface name drift)
- Disabled interfaces have `LinkLocalAddressing = no` (no unnecessary link-local traffic)
- VLAN interfaces properly parented to bond/batman devices
- Bridge members have no IP configuration (IP only on bridge itself)
- WireGuard interfaces at priority 40- (after all other netdevs)

### Security Concerns

#### 1. No `ct state invalid drop` in Generated Ruleset (MEDIUM)
The generated ruleset lacks an explicit `ct state invalid drop` rule. Invalid packets are packets that conntrack cannot associate with any known connection. While the default drop policy catches most cases, some invalid packets might match the `established,related` rule if conntrack state is confused (e.g., during TCP sequence number wrap-around or certain attack scenarios).

#### 2. DNS Interception Targets Legacy Address (LOW)
```nft
udp dport 53 dnat to 10.0.11.1:53
```
DNS interception redirects to `10.0.11.1` (legacy address) rather than `10.97.11.1`. This is presumably intentional during migration but should be updated post-migration.

#### 3. DNAT SSH Port Forward Source Restriction (LOW)
The SSH DNAT rule is correctly restricted to `iifname "wg-ba"`, meaning only traffic arriving via the WireGuard BA tunnel can trigger the port forward. This is good — SSH to ordis is not exposed on the WAN.

---

## Overall Summary

The router6 infrastructure represents a **high-quality, security-conscious network architecture**. The Nix-based approach provides several security advantages over traditional router configurations:

1. **Reproducibility**: The entire router configuration is deterministic and version-controlled
2. **Auditability**: Configuration is declarative Nix, not imperative shell scripts
3. **Build-time validation**: 35+ assertions catch misconfigurations before deployment
4. **Test coverage**: 22+ automated checks validate security properties
5. **Immutable infrastructure**: Impermanent root filesystem limits persistence of compromise

The zone-based firewall model with default-deny policies, combined with VLAN segmentation, provides strong network isolation. The DNS interception feature addresses a real-world security gap (IoT devices bypassing local DNS). The WireGuard VPN configuration with tight allowedIPs and zone isolation is well-designed.

### Maturity Assessment

| Category | Rating | Notes |
|----------|--------|-------|
| Firewall design | Excellent | Default-deny, zone-based, stealth mode |
| Network segmentation | Excellent | 8 VLANs, 6 zones, proper isolation |
| IPv6 security | Very Good | Full dual-stack, correct NDP handling, ULA |
| Secrets management | Very Good | sops-nix, age encryption, proper permissions |
| SSH hardening | Excellent | Post-quantum KEx, key-only, modern ciphers |
| DNS security | Very Good | DNSSEC, local domain blocking, DNS interception |
| Test coverage | Very Good | Comprehensive but some gaps |
| Egress filtering | Needs Improvement | Only on non-router hosts |
| Monitoring security | Needs Improvement | Metrics exposed too broadly |

---

## Overall Recommendations

### Priority 1 (Should Fix)

1. **Add `ct state invalid drop`** to both input and forward chains in the router6 base rules. This is a standard firewall hardening measure that prevents conntrack state confusion attacks.

2. **Add router output chain egress filtering.** The router itself should have egress restrictions to limit the blast radius of a compromised process. At minimum, restrict outbound to DNS (53), NTP (123), DHCP (67-68), HTTP/S (80, 443), SSH (22), WireGuard (38506, 59362), and ICMP.

### Priority 2 (Should Consider)

3. **Restrict Prometheus node exporter** to the monitoring VLAN/host. System metrics should not be accessible from all trusted zones.

4. **Add rate limiting** to ICMP echo and DNS accept rules to prevent resource exhaustion from trusted zones.

5. **Validate VLAN tag range** in the type system (`types.ints.between 1 4094`).

6. **Add `ct state invalid drop` test** to the VM integration test suite to verify the rule is present and functional.

### Priority 3 (Nice to Have)

7. **Align kresd listen interfaces** with zones that permit DNS access, removing unnecessary listeners.

8. **Add a negative DNS interception test** — verify that a device using `8.8.8.8` actually gets redirected to the router's DNS.

9. **Document the security model** in a dedicated section of CLAUDE.md or a security-model.md file, covering zone trust levels, traffic flow assumptions, and DNS interception behavior.

10. **Consider logging dropped packets** with rate limiting on the input/forward chain default drop policies for security monitoring.

11. **Clean up legacy address references** post-migration (DNS interception target, Chrony ACLs, /etc/hosts entries).

---

## Addendum: Additional Observations

The following observations emerged after the main audit and are worth noting for operational security and maintainability.

### A1. WireGuard wg-ba Security Model is Implicit (MEDIUM)

The wg-ba tunnel uses the `isolated` zone (no input, no forward, no ICMP) and then uses `extraForwardRules` to punch specific holes for DMZ↔wg-ba and wg-ba→ordis traffic. This is the correct pattern — start fully locked down, add explicit exceptions — but it means the wg-ba security posture lives entirely in the `extraForwardRules` list rather than the zone model. The `extraForwardRules` escape hatch bypasses zone-level validation: rules specify raw `iifname`/`oifname`, get no assertion checks, and sit in a flat list mixed with unrelated cross-zone rules (ordis→roer OIDC, DMZ→legram ACME, DMZ→ymir Loki). If someone later adds a rule to that list without understanding the intent, it could silently widen access.

**Recommended approach: Create a dedicated `ba-tunnel` zone.** The existing `wg-vpn` interface already follows this pattern — it uses a dedicated `vpn` zone with `accessTo` and `inputRules` defined entirely within the zone model. wg-ba is the outlier, relying on `isolated` + escape hatches instead of a proper zone. A dedicated zone would provide several security benefits:

1. **The zone definition documents the security intent** — someone reading `zones.ba-tunnel` immediately sees what wg-ba can and cannot do, without parsing a flat list of extraForwardRules.
2. **Zone assertions apply** — accessTo/forwardRules mutual exclusivity, zone name validation, and automatic iifname/oifname injection all engage.
3. **The DMZ→wg-ba direction becomes expressible** within the zone model — either via `untrusted.forwardRules.ba-tunnel` or by adding `ba-tunnel` to `untrusted.accessTo`.
4. **The wg-ba→ordis direction** fits in `ba-tunnel.forwardRules.untrusted` with `ip.daddr` filtering — the zone model already supports per-rule IP restrictions.

The remaining `extraForwardRules` (ordis→roer OIDC, DMZ→legram ACME, DMZ→ymir Loki) are all brDMZ→brINFRA cross-zone rules. Those could move into `untrusted.forwardRules.management`, which would **eliminate `extraForwardRules` entirely** for thebeyond. This would mean the entire firewall policy is expressed within the zone model — fully validated and auditable, with no escape hatches in use.

**Fallback recommendation:** If a dedicated zone is not feasible, at minimum add a comment block in `router.nix` near the `extraForwardRules` section explaining the wg-ba security model: that the `isolated` zone provides the deny-all base, and each `extraForwardRule` is an explicit, audited exception.

### A2. DNS Interception Exclusion List is a Subtle Operational Dependency (MEDIUM)

The phantasma exclusion in the DNS DNAT rules is essential — without it, phantasma's recursive queries would loop back to the router, breaking DNS resolution entirely. This is a silent failure mode: adding a second recursive resolver (e.g., during migration or failover) without adding it to the exclusion list would cause DNS to fail for that host with no obvious error.

**Recommendation:** Document this dependency inline in `router.nix` near the `extraNatRules` section. Consider whether the exclusion list could be derived automatically from the `dns.upstream` configuration rather than hardcoded.

### A3. Test Suite as a Security-Critical Artifact (NOTE)

The VM integration test suite (`router6-firewall.nix`, `router6-firewall-zones.nix`) verifies that dropped traffic is *truly* dropped from a network perspective — not just that the nftables rules look correct on paper. This is a level of security assurance that most home and even enterprise router configurations lack entirely. The test suite should be treated as a security-critical artifact: any new firewall rule or zone change should come with a corresponding test that validates the intended behavior from a network perspective.

### A4. No Firewall Drop Logging (LOW-MEDIUM)

There are no `log` rules anywhere in the generated firewall. Dropped packets produce no log entries. For a home router this is reasonable (avoids log spam from port scans and broadcast noise), but it means there is zero visibility into blocked attack traffic or misconfiguration-induced drops.

The host does ship logs to Loki via promtail (`promtail-client.enable = true`), so the log pipeline infrastructure is already in place. Adding rate-limited logging on the default drop policies would feed into the existing monitoring stack with minimal additional effort.

**Recommendation:** Add rate-limited drop logging to the input and forward chain default policies, e.g.:
```nft
limit rate 5/minute log prefix "DROP-INPUT: " counter drop
limit rate 5/minute log prefix "DROP-FORWARD: " counter drop
```
This provides visibility for security monitoring and debugging without generating excessive log volume. Since promtail is already configured, these logs would automatically flow to Loki for analysis.
