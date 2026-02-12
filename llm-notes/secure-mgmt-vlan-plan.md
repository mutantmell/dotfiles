# Secure Management VLAN Split Plan

## Overview

Split the current `vMGMT` (VLAN 10) into two VLANs with distinct security profiles:

- **vMGMT (VLAN 10)** — Networking gear (APs, managed switch). Heavily locked down: no internet, no inter-VLAN access, management SSH only from the router.
- **vINFRA (VLAN 11)** — Infrastructure (NAS, VM hosts, DNS). Moderately locked down: inter-host communication for NFS, internet for self-updating, SSH from router and admin workstation.

### Threat Model

| Device Class | Compromise Risk | Compromise Impact | Lockdown Level |
|---|---|---|---|
| APs / Switch | Higher (exposed to wireless attacks, firmware vulnerabilities) | L2 eavesdropping, MitM on bridged traffic | Maximum: no internet, no lateral movement |
| NAS | Medium (network-exposed services: NFS, SMB) | Data exfiltration, ransomware on shared storage | High: restrict NFS to specific IPs, host firewall |
| VM Hosts | Lower (no exposed services beyond SSH) | Guest VM compromise, pivot to NAS via NFS | High: host firewall, restricted SSH |
| DNS (alfheim) | Lower (MicroVM on router, minimal attack surface) | DNS poisoning, traffic redirection | High: moves to vINFRA, no direct external exposure |

### Architecture: Before and After

**Before:**
```
vMGMT (VLAN 10) — trust: management — 10.0.10.0/24
├── yggdrasil    10.0.10.1   (router)
├── alfheim      10.0.10.2   (DNS MicroVM on yggdrasil)
├── vanaheim     10.0.10.30  (VM host)
├── muspelheim   10.0.10.31  (VM host)
├── jotunheimr   10.0.10.32  (NAS)
└── APs          10.0.10.100-200 (DHCP pool)
    All devices can freely communicate with each other.
    All devices have full access to router services.
    All devices can forward to internet.
```

**After:**
```
vMGMT (VLAN 10) — trust: network — 10.0.10.0/24
├── yggdrasil    10.0.10.1   (router gateway)
└── APs/Switch   10.0.10.100-200 (DHCP pool) or static
    Devices can ONLY reach the router for DHCP/NTP.
    No internet. No access to other VLANs.
    SSH only FROM the router TO the devices.

vINFRA (VLAN 11) — trust: management — 10.0.11.0/24
├── yggdrasil    10.0.11.1   (router gateway)
├── alfheim      10.0.11.2   (DNS MicroVM on yggdrasil)
├── vanaheim     10.0.11.30  (VM host)
├── muspelheim   10.0.11.31  (VM host)
└── jotunheimr   10.0.11.32  (NAS)
    Devices can communicate with each other (NFS, monitoring).
    Internet access for updates (filtered egress).
    SSH from router + admin workstation on vHOME.
```

---

## 1. New Trust Level: `network`

### 1.1 Add to trust enum

**File:** `modules/router6/default.nix` (line 59)

Add `"network"` to the trust enum:
```nix
trust = mkOption {
  type = types.nullOr (types.enum [
    "external"      # WAN - untrusted, NAT source
    "management"    # Infrastructure - full router access, can reach internet
    "trusted"       # User devices - can access other internal networks
    "untrusted"     # Guest/IoT - internet only, isolated from other networks
    "isolated"      # No internet, no internal access
    "network"       # Networking gear - DHCP/NTP only, no internet, no forwarding
  ]);
  default = null;
  description = "Trust level for firewall rules";
};
```

### 1.2 Update interface selectors

**File:** `modules/router6/default.nix` (lines 254-261)

The `network` trust level should NOT be included in `internalInterfaces` (no internet forwarding) and NOT in `trustedInterfaces` (no full router service access):

```nix
# These remain unchanged — "network" is intentionally excluded from both:
internalInterfaces = interfacesWithTrust ["management" "trusted" "untrusted"];
trustedInterfaces = interfacesWithTrust ["management" "trusted"];

# Add a new selector for network gear:
networkInterfaces = interfacesWithTrust "network";
```

### 1.3 Add firewall rules for `network` trust

**File:** `modules/router6/default.nix` — input chain (after line 1261)

```nix
${optionalString (networkInterfaces != []) ''
# Networking gear: DHCP and NTP only (no DNS, no other services)
iifname ${netIfaces} udp dport { 67, 123 } accept
iifname ${netIfaces} icmp type { echo-request, echo-reply } accept
iifname ${netIfaces} icmpv6 type { echo-request, echo-reply } accept
''}
```

The `network` trust level gets:
- **DHCP** (UDP 67) — for IP assignment
- **NTP** (UDP 123) — for time synchronization
- **ICMP echo** — for debugging/monitoring
- **IPv6 Neighbor Discovery** — already accepted globally (line 1245)
- **Nothing else** — no DNS (APs don't need to resolve hostnames), no SSH to router, no internet forwarding

Note: DNS is intentionally excluded. APs operate as L2 bridges and don't resolve hostnames. If a specific device needs DNS, it can be added as an extra input rule.

The forward chain needs no changes — `network` interfaces are not in `internalInterfaces`, so they're already excluded from all forwarding rules. Traffic from networking gear cannot reach any other VLAN or the internet.

### 1.4 Egress filtering for `management` (vINFRA)

The `management` trust level currently has unrestricted internet access via the forward chain (it's in `internalInterfaces`). We should add targeted egress filtering so infra devices can only reach the internet for specific purposes.

**File:** `modules/router6/default.nix` — forward chain, or via `extraForwardRules` in `hosts/yggdrasil/default.nix`

This can be implemented via `extraForwardRules` on yggdrasil to avoid modifying the core module for now:

```nix
extraForwardRules = [
  # ... existing rules ...

  # vINFRA egress: allow only update-related traffic to internet
  { iifname = "vINFRA.br0"; oifname = "wan"; tcp.dport = 443; verdict = "accept";
    comment = "vINFRA: HTTPS for updates (cache.nixos.org, github)"; }
  { iifname = "vINFRA.br0"; oifname = "wan"; udp.dport = 123; verdict = "accept";
    comment = "vINFRA: NTP to internet pools"; }
  { iifname = "vINFRA.br0"; oifname = "wan"; verdict = "drop";
    comment = "vINFRA: drop all other internet-bound traffic"; }
];
```

This allows infra devices to:
- Pull Nix substitutions / updates over HTTPS (port 443)
- Sync time via NTP (port 123)
- Nothing else outbound to the internet

DNS resolution for infra devices goes to the router (10.0.11.1), which forwards to alfheim — this is intra-VLAN, not egress to the internet.

---

## 2. Router Changes (yggdrasil)

### 2.1 Add vINFRA VLAN

**File:** `hosts/yggdrasil/default.nix` — inside `router6.topology.br0.vlans`

Add the new VLAN:
```nix
# Infrastructure network - NAS, VM hosts, DNS
"vINFRA.br0" = {
  tag = 11;  # -> fdc6:55f2:0a5e:b::1/64
  network = {
    type = "static";
    addresses = [ "10.0.11.1/24" ];
    subnetId = 11;
    trust = "management";
    dhcp.enable = true;
    dhcp6.enable = true;
  };
};
```

### 2.2 Change vMGMT trust level

**File:** `hosts/yggdrasil/default.nix` — existing vMGMT definition

Change from `management` to `network`:
```nix
"vMGMT.br0" = {
  tag = 10;
  network = {
    type = "static";
    addresses = [ "10.0.10.1/24" ];
    subnetId = 10;
    trust = "network";  # Changed from "management"
    dhcp.enable = true;
    dhcp6.enable = true;
  };
};
```

Update the comment on vMGMT from "Management network - trusted devices and infrastructure" to "Network gear - APs and managed switch".

### 2.3 Update alfheim MicroVM bridge

**File:** `hosts/yggdrasil/default.nix` — systemd.network for MicroVM tap

The current config bridges `vm-10-*` tap interfaces to `vMGMT.br0`. Alfheim's tap interface is named `vm-10-alfheim` (VLAN 10 prefix). We need to either:

**Option A (recommended):** Rename alfheim's tap to `vm-11-alfheim` and add a new bridge rule:
```nix
# Bridge microVM tap interfaces into the infrastructure network
systemd.network.networks."10-vm-infra" = {
  matchConfig.Name = "vm-11-*";
  networkConfig = {
    Bridge = "vINFRA.br0";
    DHCP = "no";
    LinkLocalAddressing = "no";
  };
  linkConfig.RequiredForOnline = "no";
};
```

And in alfheim's microvm.nix, change the tap interface:
```nix
microvm.interfaces = [{
  type = "tap";
  id = "vm-11-alfheim";  # Changed from vm-10-alfheim
  mac = "5E:11:AD:01:00:02";  # Updated MAC (VLAN 11 prefix)
}];
```

**Option B:** Keep the tap name and add a specific match. Option A is cleaner since it follows the existing naming convention (VLAN tag in tap name).

Remove the old `vm-10-*` bridge rule (line 315-323) since no MicroVMs remain on vMGMT:
```nix
# Remove this block:
# systemd.network.networks."10-vm-mgmt" = { ... };
```

### 2.4 Update DNS configuration

**File:** `hosts/yggdrasil/default.nix`

Update DNS upstream to alfheim's new IP:
```nix
dns = {
  upstream = [ "10.0.11.2" ];  # Changed from 10.0.10.2
  useDHCPFallback = true;
  localDomain = "local";
};
```

### 2.5 Update DNS interception rules

**File:** `hosts/yggdrasil/default.nix` — `firewall.extraNatRules`

Update alfheim's IP in DNS interception exclusions:
```nix
# DNS interception - exclude alfheim on vINFRA
{
  ip.saddr = { not = "10.0.11.2"; };          # Changed from 10.0.10.2
  ip.daddr = { not = [ "10.0.11.1" "10.0.11.2" ]; };  # Updated for vINFRA
  udp.dport = 53;
  verdict = { dnat = "10.0.11.1:53"; };       # Router's vINFRA address
  comment = "Intercept DNS bypass (UDP)";
}
```

**Important consideration:** DNS interception currently uses hardcoded IPs. Since VLANs have different router gateway IPs (10.0.10.1 for vMGMT, 10.0.11.1 for vINFRA, 10.0.20.1 for vHOME, etc.), the DNAT target should match the source VLAN's gateway. However, since the router itself receives the redirected query on any interface and forwards to alfheim, using a single DNAT target that the router listens on is sufficient. The current approach of DNATting to the router's address on a specific interface works because kresd/kea listens on all internal interfaces.

The simplest correct approach: DNAT to 127.0.0.1:53 (localhost) or keep pointing to a specific interface. Since kresd binds to all trusted/internal interfaces, any of the router's IPs works. For clarity, update the existing rules to exclude alfheim's new IP (10.0.11.2) and DNAT to 10.0.11.1 (or keep using 10.0.10.1 — both are valid since they're both router addresses).

Actually, the cleanest approach is to leave the DNAT target as-is and only update the exclusion IPs, since the router processes DNS on any of its interfaces. But we need to make sure that DNS interception covers ALL VLANs, including vINFRA. Since vINFRA is in `internalInterfaces` (via "management" trust), and the NAT rules apply to all traffic, this should work automatically.

### 2.6 Update `/etc/hosts`

**File:** `hosts/yggdrasil/default.nix`

```nix
networking.extraHosts = ''
  10.0.11.1 yggdrasil
  10.0.11.1 yggdrasil.local
  10.0.11.2 alfheim
  10.0.11.2 alfheim.local
  10.0.20.30 gridr.local
  10.0.100.40 surtr.local
  10.0.100.50 bragi.local
  10.0.100.51 njord.local
'';
```

Note: yggdrasil's canonical IP changes to its vINFRA address (10.0.11.1) since that's the infrastructure management interface. It also has 10.0.10.1 on vMGMT, but for hostname resolution, the infra address is more useful.

---

## 3. Infrastructure Host Changes

### 3.1 alfheim (DNS MicroVM on yggdrasil)

**File:** `hosts/yggdrasil/guests/alfheim/microvm.nix`

Change tap interface name and MAC:
```nix
microvm.interfaces = [{
  type = "tap";
  id = "vm-11-alfheim";
  mac = "5E:11:AD:01:00:02";
}];
```

**File:** `hosts/yggdrasil/guests/alfheim/default.nix`

Update network configuration:
```nix
systemd.network.networks."20-tap" = {
  matchConfig.Type = "ether";
  matchConfig.MACAddress = "5E:11:AD:01:00:02";
  networkConfig = {
    Address = [ "10.0.11.2/24" ];  # Changed from 10.0.10.2
    Gateway = "10.0.11.1";         # Changed from 10.0.10.1
    DNS = [ "127.0.0.1" ];
    IPv6AcceptRA = true;
    DHCP = "no";
  };
};
```

Remove the `10.97.10.2/24` address if it's no longer needed (appears to be a secondary/test address).

Update `/etc/hosts`:
```nix
networking.extraHosts = ''
  10.0.11.1 yggdrasil.local
  10.0.20.30 gridr.local
  10.0.100.40 surtr.local
'';
```

### 3.2 vanaheim (VM host)

**File:** `hosts/vanaheim/default.nix` — initrd network (for ZFS remote unlock)

Change VLAN 10 to VLAN 11:
```nix
boot.initrd.systemd.network = {
  netdevs."20-enp88s0.11" = {
    netdevConfig.Kind = "vlan";
    netdevConfig.Name = "enp88s0.11";
    vlanConfig.Id = 11;
  };
  networks."20-enp88s0" = {
    matchConfig.Name = "enp88s0";
    networkConfig.DHCP = "no";
    networkConfig.LinkLocalAddressing = "no";
    vlan = [ "enp88s0.11" ];
  };
  networks."20-enp88s0.11" = {
    matchConfig.Name = "enp88s0.11";
    networkConfig.DHCP = "no";
    networkConfig.IPv6PrivacyExtensions = "kernel";
    networkConfig.Address = [ "10.0.11.30/24" ];
    networkConfig.MulticastDNS = true;
    networkConfig.DNS = [ "10.0.11.1" ];
    routes = [{ Gateway = "10.0.11.1"; }];
  };
};
```

**File:** `hosts/vanaheim/microvm.nix` — runtime network

Same pattern: change `.10` to `.11`, update addresses and gateway:
```nix
netdevs."20-enp88s0.11" = {
  netdevConfig.Kind = "vlan";
  netdevConfig.Name = "enp88s0.11";
  vlanConfig.Id = 11;
};
```
```nix
networks."20-enp88s0" = {
  matchConfig.Name = "enp88s0";
  networkConfig.DHCP = "no";
  networkConfig.LinkLocalAddressing = "no";
  vlan = [
    "enp88s0.11"   # Changed from .10
    "enp88s0.20"
    "enp88s0.100"
  ];
};
networks."20-enp88s0.11" = {
  matchConfig.Name = "enp88s0.11";
  networkConfig.DHCP = "no";
  networkConfig.IPv6PrivacyExtensions = "kernel";
  networkConfig.Address = [ "10.0.11.30/24" ];
  networkConfig.MulticastDNS = true;
  routes = [{ Gateway = "10.0.11.1"; }];
};
```

### 3.3 muspelheim (VM host)

**File:** `hosts/muspelheim/default.nix`

Same pattern as vanaheim. Change all VLAN 10 references to VLAN 11:

- initrd network: `eno1.10` -> `eno1.11`, address `10.0.10.31/24` -> `10.0.11.31/24`, gateway/DNS `10.0.10.1` -> `10.0.11.1`
- runtime network (in same file): same changes
- NFS mounts: `10.0.10.32` -> `10.0.11.32` (see section 4)

### 3.4 jotunheimr (NAS)

**File:** `hosts/jotunheimr/default.nix`

Change VLAN 10 to VLAN 11:
```nix
netdevs."20-enp4s0.11" = {
  netdevConfig.Kind = "vlan";
  netdevConfig.Name = "enp4s0.11";
  vlanConfig.Id = 11;
};
```
```nix
networks."20-enp4s0" = {
  matchConfig.Name = "enp4s0";
  networkConfig.DHCP = "no";
  networkConfig.LinkLocalAddressing = "no";
  vlan = [
    "enp4s0.11"   # Changed from .10
    "enp4s0.20"
    "enp4s0.100"
  ];
};
networks."20-enp4s0.11" = {
  matchConfig.Name = "enp4s0.11";
  networkConfig.DHCP = "no";
  networkConfig.IPv6PrivacyExtensions = "kernel";
  networkConfig.Address = [ "10.0.11.32/24" ];
  networkConfig.MulticastDNS = true;
  networkConfig.LLMNR = true;
  networkConfig.DNS = [ "10.0.11.1" ];
  routes = [{ Gateway = "10.0.11.1"; }];
};
```

---

## 4. NFS/Storage Hardening

### 4.1 Tighten NFS exports

**File:** `hosts/jotunheimr/nas.nix`

Change subnet-wide exports to per-IP exports for VM hosts, and re-enable `root_squash` where possible:

```nix
services.nfs.server = {
  enable = true;
  exports = ''
    # Media: VM hosts get RW (for virtiofs passthrough to guests)
    #        vHOME gets RW with root_squash (user workstations)
    /data/media 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)

    # Data: VM hosts get RW, vHOME gets RW with root_squash
    /data/data 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)

    # Read-only exports for controlled access
    /export/ro/media 10.0.11.0/24(ro) 10.0.20.0/24(ro)
    /export/rw/media 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)

    /export/ro/data 10.0.11.0/24(ro) 10.0.20.0/24(ro)
    /export/rw/data 10.0.11.30(rw,sync,no_subtree_check,no_root_squash) 10.0.11.31(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check)

    # Backup: broader access for backup clients
    /export/rw/backup 10.0.11.0/24(rw,sync,no_subtree_check,no_root_squash) 10.0.20.0/24(rw,sync,no_subtree_check) 10.1.10.0/24(rw,sync,no_subtree_check,no_root_squash) 10.1.20.0/24(rw,sync,no_subtree_check,no_root_squash)
  '';
};
```

Key changes:
- **VM hosts (10.0.11.30, 10.0.11.31):** Keep `no_root_squash` — they need root-level NFS operations for virtiofs passthrough with correct UID/GID mapping
- **vHOME (10.0.20.0/24):** Enable `root_squash` (default) — user workstations should not have root access to NFS
- **Old vMGMT subnet (10.0.10.0/24):** Removed entirely — networking gear has no business accessing NFS
- Per-IP exports for VM hosts prevent any other device on vINFRA from mounting NFS shares with root privileges

### 4.2 Update NFS mount targets

**File:** `hosts/muspelheim/default.nix`

```nix
fileSystems."/mnt/data" = {
  device = "10.0.11.32:/data/data";  # Changed from 10.0.10.32
  fsType = "nfs";
};
fileSystems."/mnt/media" = {
  device = "10.0.11.32:/data/media/";  # Changed from 10.0.10.32
  fsType = "nfs";
};
```

**File:** `hosts/vanaheim/default.nix` (currently commented out)

If/when re-enabled:
```nix
fileSystems."/mnt/data" = {
  device = "10.0.11.32:/data/data";
  fsType = "nfs";
};
fileSystems."/mnt/media" = {
  device = "10.0.11.32:/data/media/";
  fsType = "nfs";
};
```

### 4.3 Samba considerations

The current Samba config uses `security = "user"` with `map to guest = "Bad User"`. This means unknown usernames fall through to guest access. The shares have `guest ok = "no"`, which means a valid user/password is required — this is already reasonable.

However, the `valid users` and `force user` lines are commented out. Uncommenting these would restrict each share to the `mjollnir` user, which is better practice:

```nix
drive = {
  path = "/data/drive";
  browseable = "yes";
  "guest ok" = "no";
  "read only" = "no";
  "valid users" = "mjollnir";
  "force user" = "mjollnir";
};
```

This is a separate change that can be done independently of the VLAN split.

---

## 5. Host-Based Firewalls

### 5.1 jotunheimr (NAS)

**File:** `hosts/jotunheimr/nas.nix` or `hosts/jotunheimr/default.nix`

Replace the current open firewall with restricted rules:

```nix
networking.firewall = {
  enable = true;

  # NFS: only from specific VM hosts on vINFRA
  extraCommands = ''
    # NFS from VM hosts only
    iptables -A INPUT -s 10.0.11.30 -p tcp --dport 2049 -j ACCEPT
    iptables -A INPUT -s 10.0.11.31 -p tcp --dport 2049 -j ACCEPT
    iptables -A INPUT -s 10.0.20.0/24 -p tcp --dport 2049 -j ACCEPT

    # SMB from vHOME only (user workstations)
    iptables -A INPUT -s 10.0.20.0/24 -p tcp --dport 445 -j ACCEPT
    iptables -A INPUT -s 10.0.20.0/24 -p tcp --dport 139 -j ACCEPT
    iptables -A INPUT -s 10.0.20.0/24 -p udp --dport 137 -j ACCEPT
    iptables -A INPUT -s 10.0.20.0/24 -p udp --dport 138 -j ACCEPT

    # WSDD from vHOME only
    iptables -A INPUT -s 10.0.20.0/24 -p tcp --dport 5357 -j ACCEPT
    iptables -A INPUT -s 10.0.20.0/24 -p udp --dport 3702 -j ACCEPT
  '';

  # SSH: from router and admin workstation only
  allowedTCPPorts = [ ];  # Remove the blanket port opens
  # SSH is handled by openssh module, restrict via:
  # TODO: Use nftables interface to restrict SSH sources
};
```

**Better approach using NixOS firewall richRules (nftables):**

Since NixOS 24.05+, the firewall supports nftables. The cleaner approach depends on which firewall backend is in use. If using the default iptables backend, use `extraCommands`. If using nftables, use `extraInputRules`.

The key principle: remove the blanket `allowedTCPPorts = [ 445 139 2049 5357 ]` and replace with source-restricted rules.

For SSH restriction, the `openssh` module opens port 22 globally. To restrict SSH sources, add rules before the openssh rule:

```nix
networking.firewall.extraCommands = ''
  # SSH only from router and admin workstation (vHOME)
  iptables -I INPUT -p tcp --dport 22 -s 10.0.11.1 -j ACCEPT
  iptables -I INPUT -p tcp --dport 22 -s 10.0.20.0/24 -j ACCEPT
  iptables -I INPUT -p tcp --dport 22 -j DROP
'';
```

Note: The exact syntax depends on whether you use iptables or nftables as the firewall backend. The above uses iptables for compatibility with the current NixOS default.

### 5.2 vanaheim (VM host)

**File:** `hosts/vanaheim/microvm.nix` or `hosts/vanaheim/default.nix`

VM hosts need minimal open ports — only SSH for management:

```nix
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ ];  # No blanket open ports
  extraCommands = ''
    # SSH only from router and admin workstation
    iptables -I INPUT -p tcp --dport 22 -s 10.0.11.1 -j ACCEPT
    iptables -I INPUT -p tcp --dport 22 -s 10.0.20.0/24 -j ACCEPT
    iptables -I INPUT -p tcp --dport 22 -j DROP
  '';
};
```

The bridges (br20, br100) for guest VMs operate at L2 and don't need firewall rules — the host's IP stack is not involved in bridged traffic.

### 5.3 muspelheim (VM host)

Same as vanaheim:

```nix
networking.firewall = {
  enable = true;
  allowedTCPPorts = [ ];
  extraCommands = ''
    iptables -I INPUT -p tcp --dport 22 -s 10.0.11.1 -j ACCEPT
    iptables -I INPUT -p tcp --dport 22 -s 10.0.20.0/24 -j ACCEPT
    iptables -I INPUT -p tcp --dport 22 -j DROP
  '';
};
```

### 5.4 Admin workstation IP

The above rules use `10.0.20.0/24` (entire vHOME subnet) as a placeholder for the admin workstation. Once the admin workstation has a static IP via DHCP reservation, tighten this to the specific IP:

```nix
# Replace 10.0.20.0/24 with specific admin IP, e.g.:
iptables -I INPUT -p tcp --dport 22 -s 10.0.20.X -j ACCEPT
```

This should be done as a follow-up when the DHCP reservation is configured.

---

## 6. OpenWRT AP Changes

### 6.1 No VLAN changes needed for APs

APs stay on VLAN 10 (vMGMT). Their management interface remains on the same VLAN and subnet. The only thing that changes is the trust level of that VLAN on the router, which the APs don't control.

The APs do NOT need to carry VLAN 11 (vINFRA) traffic. Infrastructure devices are wired and connect through the managed switch, not through the wireless mesh. VLAN 11 traffic on br0 goes over bond0 (wired) to the switch. The APs receive VLAN 11 frames over bat0 but drop them since their bridge VLAN filtering doesn't include VLAN 11.

### 6.2 Add host-level input protection

**File:** `lib/openwrt/default.nix` — `mkMeshAPConfig` or via `extraConfig`

APs currently have `firewall4` and `nftables` removed. This is correct for bridged traffic (L2 forwarding doesn't need a firewall). However, the AP's own management interface (SSH on port 22) is unprotected.

Add lightweight nftables rules via a uci-defaults post-command or an extra file:

**Option A: Add nftables rules file to the image**

Create a file that gets included in the AP image at `/etc/nftables.d/10-mgmt-restrict.nft` (or use a uci-defaults script):

```sh
#!/bin/sh
# Restrict management access to router only

# Install minimal nftables (without firewall4 framework)
# This is already available as a dependency we need to add back

nft add table inet filter
nft add chain inet filter input '{ type filter hook input priority 0; policy drop; }'
nft add rule inet filter input ct state established,related accept
nft add rule inet filter input iifname "lo" accept
nft add rule inet filter input icmp type echo-request accept
nft add rule inet filter input icmpv6 type '{ nd-neighbor-solicit, nd-neighbor-advert, nd-router-solicit, nd-router-advert }' accept
nft add rule inet filter input ip saddr 10.0.10.1 tcp dport 22 accept
nft add rule inet filter input udp dport 68 accept  # DHCP client
```

**Consideration:** This requires `nftables` to be available on the AP. Currently `-nftables` is in the removed packages list. We need to add `nftables` back (the package, not `firewall4`). The `firewall4` framework is the OpenWRT-specific firewall management layer — we don't need that. We just need the `nft` binary:

```nix
# In removeDefaultPackages, keep removing firewall4 but NOT nftables:
removeDefaultPackages = [
  "-dnsmasq"
  "-odhcpd-ipv6only"
  "-ppp"
  "-ppp-mod-pppoe"
  "-firewall4"         # Remove OpenWRT firewall framework
  # "-nftables"        # Keep nftables for host protection
  "-wpad-basic-mbedtls"
];
```

**Option B: Use iptables instead (simpler)**

OpenWRT images typically include iptables by default. A simpler approach:

```sh
#!/bin/sh
# /etc/uci-defaults/50-host-firewall
iptables -P INPUT DROP
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT
iptables -A INPUT -p icmp -j ACCEPT
iptables -A INPUT -s 10.0.10.1 -p tcp --dport 22 -j ACCEPT
iptables -A INPUT -p udp --dport 68 -j ACCEPT
```

This can be added as a `postCommands` in the UCI defaults script or as an extra file in the image.

### 6.3 NTP server change

**File:** `lib/openwrt/default.nix` — `mkSystemConfig`

Currently APs use `0.openwrt.pool.ntp.org` etc. for NTP. Since networking gear won't have internet access, they need to use the router as their NTP server:

```nix
ntp = {
  _type = "timeserver";
  enabled = true;
  enable_server = false;
  server = [ "10.0.10.1" ];  # Router as NTP server
};
```

The router (yggdrasil) needs to run an NTP server. Add to yggdrasil's config:
```nix
services.chrony = {
  enable = true;
  extraConfig = ''
    allow 10.0.10.0/24
    allow 10.0.11.0/24
  '';
};
```

Or use `services.ntp` with appropriate access controls.

**Important:** The router's NTP service listens on a port (UDP 123). The `network` trust firewall rules already allow UDP 123, so this works.

### 6.4 Managed switch

The managed switch (OpenWRT-based, config being imported) needs the same treatment as APs:
- Stays on VLAN 10 (vMGMT)
- Host-level firewall: SSH only from router (10.0.10.1)
- NTP from router
- Must trunk VLAN 11 on ports connected to infrastructure devices

Switch VLAN trunking requirements:
- **Ports to infra hosts (vanaheim, muspelheim, jotunheimr):** Trunk VLANs 11, 20, 100
- **Ports to APs:** Trunk VLANs 10, 20, 30, 40, 41 (existing)
- **Uplink to router:** Trunk ALL VLANs (10, 11, 20, 30, 31, 40, 41, 100)

Note: Infra host ports no longer need VLAN 10 since those devices are moving to VLAN 11.

---

## 7. Admin Access Pattern (Jump Box)

### 7.1 SSH access model

```
Admin workstation (vHOME, 10.0.20.X)
├── Direct SSH to infra devices (vINFRA)
│   Allowed by: vHOME is "trusted", can forward to "management" (vINFRA)
│   Host firewall: accepts SSH from 10.0.20.X
│
├── SSH to router (yggdrasil)
│   Direct: SSH to 10.0.20.1 (router's vHOME address)
│   Or: SSH to 10.0.11.1 (router's vINFRA address, via routing)
│
└── SSH to networking gear (vMGMT) via ProxyJump
    Step 1: SSH to yggdrasil
    Step 2: yggdrasil SSH to AP/switch on 10.0.10.X
    Required because: vMGMT host firewalls only accept SSH from 10.0.10.1

Remote access (via WireGuard wg-vpn):
└── wg-vpn peer → yggdrasil → same paths as above
```

### 7.2 SSH config for admin workstation

```
Host yggdrasil
  HostName 10.0.11.1
  User root

Host vanaheim
  HostName 10.0.11.30
  User root

Host muspelheim
  HostName 10.0.11.31
  User root

Host jotunheimr
  HostName 10.0.11.32
  User root

# Networking gear - requires ProxyJump through router
Host fenrir sleipnir hugin
  ProxyJump yggdrasil
  User root

Host fenrir
  HostName 10.0.10.10

Host sleipnir
  HostName 10.0.10.11
```

### 7.3 Admin VM considerations

The user mentioned their admin workstation is Windows and may not be able to build NixOS/OpenWRT images. Options:

1. **Build on a VM host:** Use muspelheim or jotunheimr as the build machine. SSH in, run `nix build`, then deploy from there. This keeps the build within vINFRA.
2. **Build on a NixOS VM on the Windows machine:** Run a NixOS VM on the Windows workstation with Nix configured. The VM gets vHOME network access and can build + deploy.
3. **Use the Attic cache (hrungnir):** Build on any capable machine, push to Attic cache, then trigger pulls from target machines.

For deploy-rs specifically, the build host needs SSH access to target machines. The natural build host is one of the VM hosts (muspelheim has the most resources after jotunheimr) or a dedicated build VM.

---

## 8. Deployment Strategy

### 8.1 Build and deploy approach

Since management devices are too underpowered/important to build their own updates:

1. **Build host:** A powerful machine (muspelheim, or a build VM on vHOME) builds all NixOS configurations
2. **Binary cache:** Push built closures to the Attic cache on hrungnir (10.0.100.31) via HTTPS
3. **Deployment:** Use deploy-rs (or `nixos-rebuild --target-host`) to push closures to each machine via SSH

For deploy-rs, add it as a flake input and configure deployment profiles:

```nix
# In flake.nix
deploy.nodes = {
  yggdrasil = {
    hostname = "10.0.11.1";
    profiles.system = {
      user = "root";
      path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.yggdrasil;
    };
    # Enable magic rollback for the router
    magicRollback = true;
    autoRollback = true;
  };
  # ... similar for other hosts
};
```

### 8.2 Deployment order

When deploying updates, the order matters because of dependencies:

1. **VM guests first** (lowest risk, easy rollback)
   - alfheim, gridr, skadi, hrungnir, bragi, surtr, ymir
2. **VM hosts** (ensure guests survive host update)
   - vanaheim, muspelheim
3. **NAS** (ensure NFS exports come back up)
   - jotunheimr
4. **Router LAST** (if this breaks, everything is offline)
   - yggdrasil — use `magic_rollback` with deploy-rs

### 8.3 Router update safety

For the router specifically:
- **deploy-rs magic_rollback:** After deploying, deploy-rs waits for confirmation. If no confirmation within timeout (default 240s), it automatically rolls back. This prevents bricking the router.
- **Alternative:** `nixos-rebuild boot --target-host yggdrasil` + manual reboot. Previous generation remains in GRUB as fallback.
- **Physical console:** Always maintain physical/serial console access to yggdrasil as last resort.

### 8.4 OpenWRT deployment

OpenWRT devices use the existing `openwrt-deploy` script (sysupgrade over SSH). Since APs only accept SSH from the router after the lockdown:

- **Deploy from the router:** SSH to yggdrasil, then run the deploy script from there
- **Or:** Deploy from the admin workstation using ProxyJump through the router
- **Network path:** Admin workstation → yggdrasil (SSH) → AP (SCP + sysupgrade)

The deploy script needs to be updated to support ProxyJump, or deployments should be run from yggdrasil itself.

---

## 9. Network Data Updates

### 9.1 Update network.json

**File:** `lib/common/data/network.json`

```json
{
  "hosts": {
    "alfheim": { "ipv4": "10.0.11.2" },
    "bragi": { "ipv4": "10.0.100.50" },
    "goo": { "ipv4": "10.1.10.23" },
    "gridr": { "ipv4": "10.0.20.30" },
    "gumba": { "ipv4": "10.0.31.20" },
    "gumbo": { "ipv4": "10.1.10.24" },
    "gumby": { "ipv4": "10.1.10.20" },
    "hrungnir": { "ipv4": "10.0.100.31" },
    "jotunheimr": { "ipv4": "10.0.11.32" },
    "muspelheim": { "ipv4": "10.0.11.31" },
    "nidavellir": { "ipv4": "10.1.20.50" },
    "njord": { "ipv4": "10.0.100.51" },
    "pokey": { "ipv4": "10.1.10.21" },
    "prickle": { "ipv4": "10.1.10.22" },
    "skadi": { "ipv4": "10.0.20.40" },
    "surtr": { "ipv4": "10.0.100.40" },
    "vanaheim": { "ipv4": "10.0.11.30" },
    "yggdrasil": { "ipv4": "10.0.11.1" },
    "ymir": { "ipv4": "10.0.20.41" }
  }
}
```

Changed entries: alfheim, jotunheimr, muspelheim, vanaheim, yggdrasil (canonical IP now on vINFRA).

### 9.2 Update any other IP references

Search the codebase for `10.0.10.` to find any remaining references that need updating. Key places to check:
- MicroVM guest configs that reference jotunheimr's NAS IP (e.g., skadi's SMB mount)
- DNS configuration in alfheim's modules (dns.nix, proxy.nix)
- Prometheus/monitoring targets in ymir
- Any scripts or deployment tools

---

## 10. IPv6 Considerations

### 10.1 Auto-generated IPv6 addresses

The router's ULA prefix `fdc6:55f2:0a5e::/48` auto-generates IPv6 addresses based on VLAN tags:

- **VLAN 10 (vMGMT):** `fdc6:55f2:0a5e:a::1/64` — unchanged, now for networking gear
- **VLAN 11 (vINFRA):** `fdc6:55f2:0a5e:b::1/64` — new, for infrastructure

This is automatic via the `subnetId` and `dhcp6.enable` settings. No additional IPv6 configuration is needed.

### 10.2 Host IPv6 addresses

Infrastructure hosts should also have IPv6 addresses on vINFRA. Since they use SLAAC (stateless address auto-configuration) from the router's Router Advertisements, they'll automatically pick up addresses in the `fdc6:55f2:0a5e:b::/64` prefix.

For static IPv6 configuration on hosts, add explicit addresses:
```nix
networkConfig.Address = [ "10.0.11.30/24" "fdc6:55f2:0a5e:b::30/64" ];
```

### 10.3 Firewall IPv6 rules

The NFS host-firewall rules in section 5 need IPv6 equivalents if NFS over IPv6 is used. For simplicity, if all NFS traffic is IPv4, the IPv6 firewall can be more permissive on the NFS ports (or simply not open them for IPv6).

---

## 11. Complete File Change List

| File | Changes |
|------|---------|
| `modules/router6/default.nix` | Add "network" trust level, add `networkInterfaces` selector, add input rules for network trust |
| `hosts/yggdrasil/default.nix` | Add vINFRA VLAN, change vMGMT trust to "network", update DNS config, update DNS interception, update extraHosts, update MicroVM bridge rules, add NTP server, add egress filtering |
| `hosts/yggdrasil/guests/alfheim/microvm.nix` | Change tap interface name and MAC |
| `hosts/yggdrasil/guests/alfheim/default.nix` | Update IP, gateway, MAC, extraHosts |
| `hosts/vanaheim/default.nix` | Change VLAN 10→11 in initrd network, update IP/gateway/DNS |
| `hosts/vanaheim/microvm.nix` | Change VLAN 10→11 in runtime network, update IP/gateway, add host firewall |
| `hosts/muspelheim/default.nix` | Change VLAN 10→11, update IP/gateway/DNS, update NFS mount targets, add host firewall |
| `hosts/jotunheimr/default.nix` | Change VLAN 10→11, update IP/gateway/DNS, add host firewall |
| `hosts/jotunheimr/nas.nix` | Tighten NFS exports to per-IP, update subnet references, restrict firewall ports by source |
| `lib/common/data/network.json` | Update IPs for alfheim, jotunheimr, muspelheim, vanaheim, yggdrasil |
| `lib/openwrt/default.nix` | Keep nftables package, change NTP servers to router IP, add host firewall script |
| `hosts/openwrt/default.nix` | No changes needed (APs stay on VLAN 10) |

---

## 12. Future Improvements (Out of Scope)

These are worth doing but are independent of the VLAN split:

1. **Samba authentication hardening:** Uncomment `valid users` / `force user` on shares
2. **wg-vpn trust level:** Consider changing from "trusted" to a more restricted level, or creating a "vpn" trust that allows vHOME access but not vINFRA/vMGMT
3. **Monitoring/alerting:** Add Prometheus exporters on infra devices, alert on unexpected connections
4. **DoT/DoH blocking:** Block port 853 outbound from untrusted/IoT VLANs to prevent DNS bypass
5. **deploy-rs integration:** Full deploy-rs flake configuration with per-host profiles and magic rollback
6. **Nix store signing:** Configure build host to sign closures, infra devices to verify signatures
