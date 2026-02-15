# Cloud Host Hardening Plan

> **Status:** Planning. The cloud host is provisioned in
> [Keycloak OIDC plan](./keycloak-oauth-oidc-plan.md) Phase 3, step 13.
> This plan covers hardening that should be applied at provisioning time.

## Context

The cloud host has a public IPv4 address and acts as the sole entry point for all
external traffic into the homelab. It runs nginx (reverse proxy) and WireGuard
(tunnel to surtr on vDMZ). Every IPv4 address is trivially discoverable by scanning
the entire address space — automated scanners will find and probe the cloud host
within minutes of provisioning.

### What the cloud host exposes

| Port | Protocol | Purpose |
|------|----------|---------|
| 443 | TCP | HTTPS — all web traffic (Jellyfin, Keycloak auth, headscale control plane, DERP relay) |
| 22 | TCP | SSH — administration (should be restricted or removed from public interface) |
| 3478 | UDP | STUN — NAT traversal for headscale (if standalone STUN is deployed here) |
| wg-cloud port | UDP | WireGuard tunnel to homelab (silent — doesn't respond to non-peers) |

WireGuard is inherently stealthy — it drops packets that aren't from valid peers
without responding. Scanners see it as a closed port.

### Threat model

The realistic threats for a homelab cloud host are:

| Threat | Likelihood | Impact |
|--------|-----------|--------|
| Automated scanning/probing | Certain | Low — noise, not targeted |
| Credential stuffing on exposed login pages | High | Medium — Keycloak brute force protection mitigates |
| Application-layer HTTP floods | Low | Medium — degrades service for real users |
| Volumetric DDoS (bandwidth saturation) | Very low (requires motivated attacker) | High — cloud host becomes unreachable |
| Targeted exploitation of known CVEs | Low | High — full compromise |

The primary goal is eliminating noise (scanning, probing, credential stuffing) and
limiting the blast radius of application-layer attacks. Volumetric DDoS is out of
scope — that requires cloud provider mitigation or a CDN like Cloudflare, which adds
a dependency and is disproportionate for a homelab.

---

## Hardening Layers

### 1. Cloud provider L3/L4 DDoS protection

Most VPS providers (Hetzner, DigitalOcean, Vultr, OVH) include basic network-layer
DDoS mitigation — SYN floods, amplification attacks, and obvious volumetric floods
are dropped before reaching the VM. This is free and requires no configuration.

**Action:** Verify the chosen provider includes this. Prefer providers with explicit
DDoS protection (Hetzner and OVH are strong here).

### 2. Minimal port exposure

nftables on the cloud host should only accept traffic on required ports. Everything
else is dropped:

```nix
networking.nftables.tables.firewall = {
  family = "inet";
  content = ''
    chain input {
      type filter hook input priority 0; policy drop;

      ct state established,related accept
      iifname "lo" accept
      ip protocol icmp accept
      ip6 nexthdr ipv6-icmp accept

      # WireGuard (wg-cloud tunnel to homelab)
      udp dport <wg-cloud-port> accept

      # HTTPS (all web traffic)
      tcp dport 443 accept

      # STUN (headscale NAT traversal, if deployed here)
      udp dport 3478 accept

      # SSH — see section 6 for options
      # tcp dport 22 accept  # restrict or remove
    }
  '';
};
```

### 3. Geo-blocking

Block inbound traffic from countries where no legitimate users exist. This
eliminates the majority of automated scanning traffic. Imprecise at borders and
for VPN users, but false positives are easy to debug with a handful of known users.

```nix
# Sketch — GeoIP filtering via nftables + MaxMind
# Download and update GeoIP database periodically
# Create an nftables set of allowed country IP ranges
# Drop all inbound TCP 443 / UDP 3478 not in the set
#
# NixOS packages: mmdb (MaxMind DB library), geoipupdate
# nftables can match against sets populated from GeoIP data
```

The allowed set should include:
- Your country
- Any countries where friends are located
- Optionally: countries where you travel

Update the GeoIP database on a schedule (MaxMind updates weekly). A systemd timer
that regenerates the nftables set from the latest database keeps it current.

### 4. Rate limiting at nginx

Rate limit requests before they enter the WireGuard tunnel. The cloud host absorbs
floods — surtr and backend services never see them.

```nginx
# Per-IP rate and connection limits
limit_req_zone $binary_remote_addr zone=general:10m rate=10r/s;
limit_conn_zone $binary_remote_addr zone=connlimit:10m;

server {
    limit_req zone=general burst=20 nodelay;
    limit_conn connlimit 20;

    # Drop requests without a valid Host header (scanners don't send one)
    if ($host !~ ^(mutantmell\.net|auth\.mutantmell\.net|vpn\.mutantmell\.net)$) {
        return 444;  # nginx drops the connection silently
    }
}
```

This is the first rate limiting layer. surtr has a second layer (S11 in the Keycloak
plan) behind the WireGuard tunnel. Keycloak has a third layer (realm-level brute
force protection). Three independent rate limiters, each on a different host.

### 5. CrowdSec

CrowdSec is a community-driven IP reputation system. When any CrowdSec user
detects an attacker, the IP is shared and blocked for all participants. The cloud
host starts with a blocklist of millions of known-bad IPs on day one.

Advantages over fail2ban:
- Shared threat intelligence (community blocklists) vs learning only from own logs
- Supports nginx log parsing and nftables bouncer (blocks at the firewall level)
- NixOS has a `services.crowdsec` module

```nix
services.crowdsec = {
  enable = true;
  # nginx log parser — detects scanning, path traversal, credential stuffing
  # nftables bouncer — adds offending IPs to an nftables drop set
};
```

CrowdSec's nftables bouncer blocks bad IPs before nginx even processes the request,
reducing load from known attackers to near zero.

### 6. SSH access to the cloud host

Three options, in order of preference:

**Option A (recommended): SSH only over WireGuard.** The cloud host's SSH daemon
listens only on the wg-cloud interface, not the public interface. Zero SSH attack
surface on the public IP. Administration requires connecting through the homelab's
WireGuard tunnel first.

```nix
services.openssh = {
  enable = true;
  listenAddresses = [
    { addr = "<wg-cloud-cloud-host-ip>"; port = 22; }
  ];
};
```

**Option B: SSH on public IP with key-only auth + fail2ban.** If Option A is
impractical during initial provisioning (before wg-cloud is established), allow SSH
on the public IP temporarily with strict controls:

```nix
services.openssh = {
  enable = true;
  settings = {
    PasswordAuthentication = false;
    PermitRootLogin = "no";
    MaxAuthTries = 3;
  };
};
services.fail2ban.enable = true;
```

Migrate to Option A once wg-cloud is established.

**Option C: Non-standard SSH port.** Not real security (port scanners find it
trivially), but reduces log noise. Only useful as a complement to Option A or B,
not on its own.

---

## What's not worth doing for a homelab

- **Cloudflare / CDN fronting** — hides the cloud host's IP and provides DDoS
  protection, but adds a third-party dependency that sees all traffic metadata.
  The WireGuard tunnel already hides the homelab's IP. Disproportionate unless
  targeted DDoS becomes a real problem.

- **Port knocking** — fragile and annoying. SSH-over-WireGuard (Option A) solves
  the same problem better.

- **WAF rulesets** — the services behind surtr are authenticated via oauth2-proxy.
  An attacker who gets past rate limiting still hits a Keycloak login page with
  brute force protection. The attack surface is narrow enough that a WAF adds
  complexity without meaningful benefit.

---

## Implementation

This hardening is applied when the cloud host is provisioned in Keycloak OIDC
Phase 3, step 13. The cloud host's NixOS configuration should include all of the
above from day one — don't provision first and harden later.

### File changes

| File | Changes |
|------|---------|
| New: cloud host NixOS config | nftables input rules, nginx rate limiting, CrowdSec, SSH config |
| New: GeoIP update timer | systemd timer + script to refresh MaxMind DB and regenerate nftables set |
| `flake.nix` | Add cloud host to nixosConfigurations |

### Checklist

- [ ] Choose VPS provider, verify L3/L4 DDoS protection
- [ ] Configure nftables input rules (minimal port exposure)
- [ ] Set up GeoIP database download and nftables set generation
- [ ] Configure nginx rate limiting and Host header validation
- [ ] Deploy CrowdSec with nginx parser and nftables bouncer
- [ ] Configure SSH access (Option A: WireGuard-only, fallback to Option B during bootstrap)
- [ ] Verify: port scan from external host shows only expected ports
- [ ] Verify: requests from blocked countries are dropped
- [ ] Verify: rate limiting engages under load
