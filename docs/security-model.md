# Security Model

This document describes the network security architecture implemented by the `router6` module.

## Zone Trust Model

All network interfaces are assigned to a **zone**. Zones define trust boundaries and control traffic flow between segments. The zone hierarchy (from most to least trusted):

| Zone           | Purpose                        | Router access | Internet           | Lateral movement                  |
| -------------- | ------------------------------ | ------------- | ------------------ | --------------------------------- |
| **management** | Infrastructure (NAS, VMs, DNS) | Full          | Filtered egress    | To trusted, untrusted, dmz        |
| **trusted**    | User devices (home LAN)        | Full          | Full               | To management, untrusted          |
| **vpn**        | Remote authenticated clients   | Full          | Via management/dmz | To management, untrusted, dmz     |
| **dmz**        | Exposed services               | DNS + DHCP    | Full               | Filtered to management, ba-tunnel |
| **untrusted**  | Guest/IoT/ADU/gaming           | DNS + DHCP    | Full               | None                              |
| **ba-tunnel**  | WireGuard site tunnel          | None          | None               | To DMZ (single host only)         |
| **network**    | APs and switches               | NTP only      | None               | None                              |
| **external**   | WAN                            | None          | N/A                | None                              |
| **isolated**   | Reserved (no interfaces)       | None          | None               | None                              |

Zones are **not a fixed enum** — they are defined per-deployment via `router6.zones.<name>`.

## Default-Deny Firewall

The firewall uses nftables with three chains, all default-deny on input/forward:

### Input chain (router services)

- **Policy: drop**
- Base rules: conntrack established/related, loopback, essential ICMP/ICMPv6, NDP
- Per-zone ICMP echo rules (with optional rate limiting via `icmpRateLimit`)
- Per-zone `inputRules` (structured DSL or raw nftables strings)
- Optional drop logging (`logDropped`) with rate-limited `log prefix "DROP-INPUT: "`

### Forward chain (inter-zone traffic)

- **Policy: drop**
- Base rules: conntrack established/related, invalid drop, TCP MSS clamping
- `accessTo` grants blanket forwarding from source zone to destination zone(s)
- `forwardRules.<dest-zone>` grants filtered forwarding with specific match criteria
- Optional drop logging with `log prefix "DROP-FORWARD: "`

### Output chain (router-originated traffic)

- **Policy: configurable** via `egressPolicy`:
  - `"accept"` (default): no restrictions, backwards compatible
  - `"log"`: policy accept with base rules + `egressRules` + rate-limited log for unmatched
  - `"drop"`: policy drop with base rules + `egressRules` only

## DNS Interception

When `dns.interception.enable = true`, the router generates DNAT rules in both `ip nat` and `ip6 nat` prerouting chains. These redirect any DNS traffic (UDP/TCP port 53) to the router's kresd resolver.

**Purpose:** Prevents devices (e.g., Google Nest, IoT) from bypassing DHCP-assigned DNS by hardcoding external resolvers.

**Exclusions:**

- The router's own IP addresses are automatically excluded from DNAT destination matching
- `dns.upstream` servers are excluded by default (source and destination) so kresd can make recursive queries
- Additional exclusions via `extraExcludeAddresses` (e.g., legacy IPs during migration)

**Targets:** Configurable via `target`/`target6`, or auto-detected from the first DNS-serving interface.

## Network Segmentation

VLANs map 1:1 to bridges, and bridges map to zones:

```
Physical NICs → bond (LACP) → batman-adv mesh
    ↓
Per-VLAN sub-interfaces (bond + batman)
    ↓
Per-VLAN bridges (brMGMT, brINFRA, brHOME, ...)
    ↓
Zone assignment (management, trusted, untrusted, dmz, ...)
```

Each bridge gets: static IPs, optional DHCP/DHCPv6 server, firewall zone. The zone assignment drives all firewall rule generation — no manual `iifname`/`oifname` rules needed.

VLAN tag validation is enforced by the bridge: only tagged frames matching the bridge's VLAN sub-interface are accepted. Untagged or mis-tagged frames are dropped at the data link layer.

## ICMP Rate Limiting

When `firewall.icmpRateLimit` is set (e.g., `"30/second burst 60 packets"`), all auto-generated ICMP echo accept rules include `limit rate` to prevent ping flood abuse while preserving diagnostic capability.

## kresd Listen Scope

kresd only listens on interfaces whose zone `inputRules` actually permit DNS (port 53 or blanket accept). Zones with only NTP or other non-DNS rules do not get kresd listeners, reducing attack surface.
