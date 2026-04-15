# Plan: Integrate Arcus (Steam Deck) into Homelab via WireGuard

## Context

Arcus is a Steam Deck running Jovian NixOS — the first managed device that will live on
the untrusted guest VLAN (VLAN 30) rather than the trusted LAN. It needs access to homelab
consumer services (Jellyfin, eventually Retrom) and must be remotely updatable via deploy-rs.

Rather than punching firewall holes from the untrusted zone to internal services, we use a
WireGuard tunnel (`wg-media`) to cryptographically authenticate arcus and place it in a
purpose-built `media` firewall zone with narrow access to specific DMZ services. This keeps
the untrusted zone truly untrusted and provides a natural migration path to headscale later.

**Deferred to future work:**

- Retrom server deployment (arcus gets the client package now)
- Moonlight/Sunshine streaming (requires headscale + desktop host)
- Headscale overlay network (requires cloud host)

## Implementation Steps

### Step 1: Add `wg-media` WireGuard interface to thebeyond router

**File:** `hosts/thebeyond/router.nix`

Add a new WireGuard device in the `topology` section (after `wg-vpn`):

```nix
# WireGuard - media consumer access (Steam Deck, etc.)
"wg-media" = {
  kind = "wireguard";
  network = {
    type = "static";
    addresses = [
      "10.100.20.1/24"
      "fdc6:55f2:0a5e:6414::1/64"
    ];
    zone = "media";
    required = false;
  };
  wireguard = {
    privateKeyFile = config.sops.secrets."wg-media-privatekey".path;
    port = 51820;
    openFirewall = true;
    peers = [
      {
        publicKey = "<arcus-wg-public-key>";  # Generated during setup
        allowedIPs = ["10.100.20.10/32" "fdc6:55f2:0a5e:6414::a/128"];
      }
    ];
  };
};
```

**Address scheme:** `10.100.X.0/24` where X=0 is ba, X=10 is vpn, X=20 is media.
IPv6 follows the same ULA pattern with `6414` (hex 20 = `14`).

### Step 2: Add `media` firewall zone to thebeyond router

**File:** `hosts/thebeyond/router.nix`

Add in the `zones` section:

```nix
media = {
  # Consumer media access: Jellyfin, Retrom (future), game streaming (future)
  # Authenticated via WireGuard — only keyed devices reach this zone
  icmpEcho = "enable";
  accessTo = [];
  forwardRules.dmz = ds {
    daddr = oracion;
    tcp.dport = 443;
    verdict = "accept";
    comment = "media -> oracion (Jellyfin)";
  };
  inputRules = [
    {
      udp.dport = 53;
      verdict = "accept";
      comment = "DNS";
    }
  ];
};
```

**Access model:**

- `accessTo = []` — no blanket zone access
- Explicit forward rules to specific DMZ hosts only (oracion for Jellyfin)
- DNS input rule so arcus can resolve `*.internal` names via the router
- No DHCP needed (WG uses static IPs)
- New forward rules added here as new services come online (Retrom, etc.)

### Step 3: Add WireGuard egress rule to thebeyond router

**File:** `hosts/thebeyond/router.nix`

In the `firewall.egressRules` section, add the new WG port:

```nix
# Change existing WireGuard egress rule:
{
  udp.dport = [38506 59362 51820];  # Add 51820
  verdict = "accept";
  comment = "WireGuard";
}
```

### Step 4: Add `wg-media-privatekey` secret to thebeyond

**File:** `hosts/thebeyond/sops.nix`

Add to the `secrets` attrset:

```nix
"wg-media-privatekey" = {
  mode = "0440";
  inherit (config.users.users."systemd-network") group;
};
```

**Manual step:** Generate the keypair and add to the encrypted secrets file:

```bash
wg genkey | tee /tmp/wg-media-private | wg pubkey > /tmp/wg-media-public
# Add wg-media-privatekey to hosts/thebeyond/secrets/secrets.yaml via sops
sops hosts/thebeyond/secrets/secrets.yaml
# Record the public key for arcus's client config
```

### Step 5: Add arcus host to network registry (on untrusted zone)

**File:** `lib/common/data/network.nix`

Add arcus to the `untrusted` zone:

```nix
untrusted = {
  vlanId = 30;
  hosts = {
    arcus = 10;  # Steam Deck (guest WiFi)
  };
};
```

This gives arcus a registered identity (`10.97.30.10`) for DNS/monitoring, even though
its primary service access goes through the WG tunnel. The untrusted zone IP is its
"physical" address on the guest WiFi; the WG IP (`10.100.20.10`) is its "service" address.

### Step 6: Add arcus to DNS

**File:** `hosts/thebeyond/microvm/guests/phantasma/modules/dns.nix`

Add `"arcus"` to the list of hosts for DNS resolution.

### Step 7: Set up sops for arcus

**File:** `.sops.yaml`

Add arcus age key and creation rule:

```yaml
# Under keys section:
- &sv_arcus <arcus-age-public-key>  # Derived from SSH host key after initial deploy

# Under creation_rules:
- path_regex: hosts/arcus/secrets/[^/]+\.yaml$
  key_groups:
    - age:
        - *ad_denai
        - *sv_arcus
```

**Note:** The age key is derived from the SSH host key, which won't exist until after
initial deployment. The sops entry can use a placeholder initially, then be updated
post-deploy (same pattern as other hosts via `setup-guest.sh` / `deploy-nixos-anywhere.sh`).

### Step 8: Create arcus sops.nix and WireGuard secret

**File:** `hosts/arcus/sops.nix` (new)

```nix
{config, ...}: {
  config.sops = {
    defaultSopsFile = ./secrets/secrets.yaml;
    age.sshKeyPaths = ["/etc/ssh/ssh_host_ed25519_key"];
    secrets = {
      "wg-media-privatekey" = {
        mode = "0440";
        group = "systemd-network";
      };
    };
  };
}
```

**File:** `hosts/arcus/secrets/secrets.yaml` (new, encrypted with sops)

Contains `wg-media-privatekey` — arcus's WireGuard private key.

**Manual step:** Generate arcus's WG keypair:

```bash
wg genkey | tee /tmp/arcus-wg-private | wg pubkey > /tmp/arcus-wg-public
# Use the public key in Step 1's peer config on thebeyond
# Encrypt the private key into hosts/arcus/secrets/secrets.yaml
```

### Step 9: Configure WireGuard client on arcus

**File:** `hosts/arcus/default.nix`

Add WireGuard client configuration using systemd-networkd (coexists with NetworkManager
for WiFi):

```nix
# WireGuard tunnel for homelab service access
networking.useNetworkd = true;

systemd.network = {
  netdevs."30-wg-media" = {
    netdevConfig = {
      Name = "wg-media";
      Kind = "wireguard";
    };
    wireguardConfig = {
      PrivateKeyFile = config.sops.secrets."wg-media-privatekey".path;
    };
    wireguardPeers = [
      {
        PublicKey = "<thebeyond-wg-media-public-key>";
        AllowedIPs = [
          "10.100.20.0/24"       # WG subnet
          "10.97.100.0/24"       # DMZ subnet (Jellyfin, etc.)
          "10.97.11.0/24"        # Management subnet (DNS resolution)
          "fdc6:55f2:0a5e:64::/64"
          "fdc6:55f2:0a5e:b::/64"
          "fdc6:55f2:0a5e:14::/64"
        ];
        Endpoint = "10.97.30.1:51820";  # Router's untrusted VLAN gateway
        PersistentKeepalive = 25;
      }
    ];
  };
  networks."40-wg-media" = {
    matchConfig.Name = "wg-media";
    address = ["10.100.20.10/24" "fdc6:55f2:0a5e:6414::a/128"];
    routes = [
      { Destination = "10.97.100.0/24"; }  # DMZ
      { Destination = "10.97.11.0/24"; }   # Management (for DNS)
    ];
    dns = ["10.97.30.1"];  # Router DNS via untrusted gateway
    domains = ["internal" "internal.mutantmell.net"];
  };
};
```

**Note:** NetworkManager manages WiFi (guest SSID). systemd-networkd manages the WG
tunnel. These coexist — NetworkManager ignores interfaces managed by networkd, and networkd
ignores WiFi interfaces managed by NM. The `networking.useNetworkd = true` line may
conflict with NM; we may need `systemd.network.enable = true` directly instead and leave
`networking.networkmanager.enable = true` as-is. This will need testing.

### Step 10: Add consumer application packages to arcus

**File:** `hosts/arcus/default.nix`

```nix
environment.systemPackages = with pkgs; [
  jellyfin-media-player  # Jellyfin client
  moonlight-qt           # Moonlight game streaming client (for future Sunshine host)
];
```

Retrom client: check nixpkgs availability. If not packaged, defer or package it.

### Step 11: Enable common modules on arcus

**File:** `hosts/arcus/default.nix`

Enable the common openssh module (required for deploy-rs):

```nix
common.openssh.enable = true;
```

The `mk-nixos` function already includes sops-nix, impermanence, and common modules.
Arcus doesn't use impermanence (ext4 root, not tmpfs), so impermanence is a no-op.

### Step 12: Add arcus to deploy-rs

**File:** `flake.nix`

Add in `deploy.nodes`:

```nix
arcus = {
  hostname = "10.100.20.10";  # WG tunnel IP
  profiles.system = {
    sshUser = "root";
    user = "root";
    path = deploy-rs.lib.x86_64-linux.activate.nixos self.nixosConfigurations.arcus;
    magicRollback = true;
    autoRollback = true;
  };
};
```

Uses the WG tunnel IP directly rather than a DNS name, since arcus isn't in the
standard internal DNS resolution path from the deploy host. Once DNS is configured
(Step 6), `arcus.internal` could be used instead, but the WG IP is more reliable
for deployment.

## File Summary

| File                                                       | Action                                                   |
| ---------------------------------------------------------- | -------------------------------------------------------- |
| `hosts/thebeyond/router.nix`                               | Add `wg-media` device, `media` zone, update egress rules |
| `hosts/thebeyond/sops.nix`                                 | Add `wg-media-privatekey` secret                         |
| `hosts/thebeyond/secrets/secrets.yaml`                     | Add encrypted WG private key (manual)                    |
| `lib/common/data/network.nix`                              | Add arcus to untrusted zone                              |
| `hosts/thebeyond/microvm/guests/phantasma/modules/dns.nix` | Add arcus to DNS                                         |
| `.sops.yaml`                                               | Add arcus age key + creation rule                        |
| `hosts/arcus/default.nix`                                  | Add WG client, packages, common.openssh                  |
| `hosts/arcus/sops.nix`                                     | New file — sops config for WG key                        |
| `hosts/arcus/secrets/secrets.yaml`                         | New file — encrypted WG private key (manual)             |
| `flake.nix`                                                | Add arcus to deploy-rs nodes                             |

## Manual / Out-of-Band Steps

1. **Generate WG keypairs** — two pairs: one for thebeyond (wg-media server), one for arcus (client)
2. **Encrypt secrets** — add private keys to respective sops-encrypted files
3. **Initial arcus deployment** — via `deploy-nixos-anywhere.sh` with the Steam Deck booted into a NixOS installer USB
4. **Post-deploy** — derive arcus's age key from SSH host key, update `.sops.yaml`, re-encrypt secrets
5. **Deploy thebeyond** — `deploy .#thebeyond` to activate the new WG interface and zone
6. **Deploy arcus** — `deploy .#arcus` over the now-active WG tunnel

## Verification

1. **WG tunnel connectivity:** From arcus, `ping 10.100.20.1` (router WG endpoint)
2. **DNS resolution:** From arcus, `resolvectl query oracion.internal` should return the DMZ IP
3. **Jellyfin access:** From arcus, `curl -k https://oracion.internal:443` should reach Jellyfin
4. **Firewall isolation:** From arcus's WG IP, verify that management hosts (other than DNS) are unreachable: `ping 10.97.11.20` (liberl) should fail
5. **deploy-rs:** From deploy host, `deploy .#arcus` should succeed over the WG tunnel
6. **Zone isolation:** From another device on the guest WiFi, verify no access to DMZ services
7. **Check suite:** `./scripts/run-checks.sh` — all existing tests pass (new config shouldn't break existing zones)

## Future Work

- **Retrom server:** Deploy retrom-server on a DMZ VM, add forward rule in media zone
- **Moonlight/Sunshine:** Deferred to headscale — Sunshine runs on desktop, needs overlay mesh
- **Headscale migration:** When headscale deploys, arcus moves from manual WG to tailnet; media zone forward rules migrate to headscale ACLs; `wg-media` interface retired
- **Monitoring:** Route Prometheus scraping to arcus via WG tunnel (routing consideration)
- **Additional media devices:** Add more WG peers to `wg-media` as needed
