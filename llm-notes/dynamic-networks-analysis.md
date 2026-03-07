# Dynamic Networks Feature (Dropped)

## Overview

The original `modules/router/default.nix` module (pre-router6 rewrite) included a
**dynamic networks** feature that allowed network topology entries — particularly
WireGuard interfaces — to have values resolved at runtime from environment variables
rather than being fully determined at Nix evaluation time. This was paired with a
**dynamic endpoint refresh** mechanism that monitored WireGuard handshake staleness and
re-resolved endpoints when connections went stale.

This feature was dropped during the router6 rewrite because it is no longer needed in
the current network topology.

## What It Did

The dynamic networks feature solved two problems:

1. **Runtime-variable network configuration**: Some WireGuard peers had endpoints
   resolved via DNS names that changed IP addresses frequently. Since systemd-networkd
   configuration files are written at activation time (during `nixos-rebuild switch`),
   a peer whose DNS name resolved to a different IP after activation would have a stale
   endpoint baked into its `.netdev` file. Dynamic networks allowed these values to be
   resolved from environment variables at service start time, rather than at Nix
   evaluation time.

2. **Stale handshake recovery**: Even after initial endpoint resolution, WireGuard
   connections could go stale if the remote peer's IP address changed. The dynamic
   endpoint refresh timer periodically checked handshake timestamps and re-resolved
   endpoints for peers that hadn't completed a handshake within a configurable threshold.

## How It Worked

### Architecture

The system had three layers:

```
┌─────────────────────────────────────────────────────────┐
│  Nix Evaluation (build time)                            │
│  ┌───────────────────┐  ┌────────────────────────────┐  │
│  │ cfg.topology      │  │ cfg.dynamic.topology       │  │
│  │ (static values)   │  │ (values can be {env="..."})│  │
│  └───────────────────┘  └────────────────────────────┘  │
│           │                         │                    │
│     whole-topology = cfg.topology // cfg.dynamic.topology│
└─────────────────────────────────────────────────────────┘
                    │                 │
          ┌────────┘                 └────────┐
          ▼                                   ▼
┌──────────────────────┐     ┌────────────────────────────┐
│ systemd.network.*    │     │ router-network-dynamic.service│
│ (written to /etc/)   │     │ (writes to /run/systemd/     │
│ (static configs)     │     │  network/ at runtime)        │
└──────────────────────┘     └────────────────────────────┘
                                      │
                              ┌───────┘
                              ▼
                    ┌──────────────────────────┐
                    │ router-wireguard-dynamic- │
                    │ endpoint-refresh.service   │
                    │ (timer: every 5 minutes)   │
                    └──────────────────────────┘
```

### Component 1: Dynamic Topology Type System

The topology option constructor `mkTopologyOpt` accepted a boolean `is-dynamic`
parameter. When `true`, every option created via `mkDynamicOpt` accepted either its
normal type OR a `{ env = "VAR_NAME"; }` attribute set:

```nix
# modules/router/default.nix lines 14-23
mkTopologyOpt = is-dynamic: let
  dynType = types.submodule {
    options.env = mkOption {
      type = types.str;
      description = "the environment variable to fetch the value from dynamically";
    };
  };
  mkDynamicOpt = base: if is-dynamic then mkOption (base // {
    type = types.either base.type dynType;
  }) else mkOption base;
in mkOption { ... };
```

In practice, only WireGuard peer endpoints used this dynamic type:

```nix
# line 247
options.endpoint = mkDynamicOpt {
  type = types.nullOr types.str;
  description = "endpoint for the peer, including port";
  example = "example.com:45678";
  default = null;
};
```

The module options then exposed two topology sections:

```nix
# line 428-438
topology = mkTopologyOpt false;        # Static topology (no env vars)
dynamic = mkOption {
  type = types.submodule {
    options.environmentFile = mkOption {  # Path to env var file
      type = types.nullOr types.str;
      default = null;
    };
    options.topology = mkTopologyOpt true;  # Dynamic topology (env vars OK)
  };
  default = {};
};
```

Both topologies were merged for firewall/routing purposes:

```nix
# line 443
whole-topology = cfg.topology // cfg.dynamic.topology;
```

With a safety assertion:

```nix
# line 784-785
assertion = lib.lists.mutuallyExclusive
  (interfaces' cfg.topology) (interfaces' cfg.dynamic.topology);
message = "Dynamic and Static interface names must be mutually exclusive";
```

### Component 2: Dynamic Network Generation Service

The `router-network-dynamic` systemd service wrote `.netdev` and `.network` files to
the volatile path `/run/systemd/network/` at boot, using `envsubst` to substitute
environment variables from a configured `EnvironmentFile`:

```nix
# lines 826-870
systemd.services."router-network-dynamic" = lib.mkIf (
  cfg.dynamic.topology != {}
) (let
  volatilePath = "/run/systemd/network";
in {
  wants = [ "network-pre.target" ];
  before = [ "network-pre.target" ];
  wantedBy = [ "network.target" ];
  path = with pkgs; [ bash envsubst ];
  script = with utils.systemdUtils.network; ''
    mkdir -p ${volatilePath}
    chown systemd-network:systemd-network ${volatilePath}
    # For each dynamic netdev: render template with envsubst, write to /run/
    # For each dynamic network: render template with envsubst, write to /run/
  '';
  preStop = ''
    # Remove all dynamic .netdev and .network files from /run/
  '';
  serviceConfig.Type = "oneshot";
  serviceConfig.EnvironmentFile = cfg.dynamic.environmentFile;
  serviceConfig.RemainAfterExit = true;
});
```

Key implementation details:

- **Ordering**: Ran before `network-pre.target`, ensuring systemd-networkd would pick up
  the dynamic files during normal network bring-up. This ordering was also critical for
  nftables integration: because the nftables ruleset was generated at build time and
  contained literal interface names from the dynamic topology (e.g., `iifname "wg-friend"`),
  the dynamic interfaces needed to exist before nftables loaded. nftables could behave
  unpredictably when rules referenced interfaces that didn't exist yet, so the dynamic
  network service had to run early enough that networkd would create the interfaces
  before nftables rules were applied.
- **Template rendering**: Used NixOS's internal `utils.systemdUtils.network.units.netdevToUnit`
  and `units.networkToUnit` to convert the Nix attrset topology into INI-style unit file
  content. The `from-dynamic` helper (line 492) converted `{ env = "VAR"; }` values
  into the literal string `"VAR"` (i.e., the env var name), which `envsubst` would then
  replace with the actual value at runtime.
- **Cleanup**: The `preStop` handler removed the volatile files, and there was a TODO
  noting that networkd would "abandon" the interfaces rather than cleanly removing them.
- **RemainAfterExit**: The oneshot service stayed "active" so that stopping it would
  trigger the preStop cleanup.

### Component 3: WireGuard Dynamic Endpoint Refresh

A separate timer-driven service checked WireGuard handshake freshness and re-resolved
stale endpoints:

```nix
# lines 872-914
systemd.services."router-wireguard-dynamic-endpoint-refresh" = let
  # Collect all WireGuard peers that have dynamicEndpointRefreshRestartSeconds set
  getWireguardConf = lib.attrsets.concatMapAttrs (name: { wireguard ? {}, ... }:
    # ... recursively collect from vlans and pppoe too
    # Filter to only peers with dynamicEndpointRefreshRestartSeconds != null
  );
  wireguard-confs = getWireguardConf whole-topology;
in lib.mkIf (wireguard-confs != {}) {
  after = [ "network-online.target" ];
  wants = [ "network-online.target" ];
  path = with pkgs; [ bash wireguard-tools ];
  script = ''
    # For each interface + peer with refresh configured:
    re=$'<publicKey>\t([0-9]+)'
    if [[ $(wg show "<iface>" latest-handshakes) =~ $re ]]; then
      if (( ($EPOCHSECONDS - ${BASH_REMATCH[1]}) > <threshold> )); then
        echo "Updating wg endpoint for iface <iface> and peer <publicKey>"
        wg set "<iface>" peer "<publicKey>" endpoint "<endpoint>"
      fi
    fi
  '';
  serviceConfig.Type = "oneshot";
  serviceConfig.EnvironmentFile = cfg.dynamic.environmentFile;
};

# Timer: every 5 minutes
systemd.timers."router-wireguard-dynamic-endpoint-refresh" = {
  wantedBy = [ "timers.target" ];
  timerConfig = {
    OnBootSec = "5m";
    OnUnitActiveSec = "5m";
    Unit = "router-wireguard-dynamic-endpoint-refresh.service";
  };
};
```

The per-peer `dynamicEndpointRefreshRestartSeconds` option (line 259-264) controlled
the staleness threshold. The script used `wg show <iface> latest-handshakes` to get
the epoch timestamp of the last successful handshake, compared it to `$EPOCHSECONDS`,
and if the difference exceeded the threshold, ran `wg set` to update the endpoint. This
forced WireGuard to re-resolve the DNS name and attempt a new handshake.

The `EnvironmentFile` was passed to this service too, so that dynamic `{ env = "..."; }`
endpoint values could be resolved.

## Example Usage

A typical deployment would have looked like:

```nix
router = {
  enable = true;

  dynamic = {
    # File containing: WG_FRIEND_ENDPOINT=friend.dyndns.org:51820
    environmentFile = "/run/secrets/dynamic-network-env";

    topology = {
      "wg-friend" = {
        wireguard = {
          privateKeyFile = "/run/secrets/wg-friend-key";
          port = 51820;
          peers = [{
            publicKey = "...";
            allowedIps = [ "10.200.0.0/24" ];
            endpoint = { env = "WG_FRIEND_ENDPOINT"; };  # Resolved at runtime
            persistentKeepalive = 25;
            dynamicEndpointRefreshRestartSeconds = 135;   # Re-resolve after 135s stale
          }];
        };
        network = {
          type = "static";
          static-addresses = [ "10.200.0.1/24" ];
          trust = "untrusted";
        };
      };
    };
  };

  topology = {
    # ... static interfaces defined here as normal ...
  };
};
```

An external script (or sops secret template) would maintain the environment file,
updating it when DNS changes were detected. Restarting `router-network-dynamic.service`
would regenerate the networkd files with the new values.

## Analysis

### Strengths

- **Firewall integration via topology merge**: This was a key design win. Because
  `whole-topology = cfg.topology // cfg.dynamic.topology`, all downstream derivations
  — including `interfacesWithTrust`, `interfacesWhere`, and the nftables ruleset —
  automatically incorporated dynamic interfaces. A dynamic WireGuard interface with
  `trust = "untrusted"` would appear in nftables `iifname`/`oifname` rules alongside
  static interfaces, with no special handling needed. The firewall, NAT rules, DHCP
  server bindings, and DNS listener interfaces all "just worked" for dynamic interfaces
  because they were derived from the merged topology at Nix evaluation time. For
  example, `interfacesWithTrust "untrusted"` (line 1112) would include both static and
  dynamic interfaces, and those names would appear directly in generated nftables rules
  like `iifname { "eth1", "wg-friend" } ... accept`.
- **Clean separation**: Dynamic and static topologies were clearly separated in
  configuration, merged only for firewall/routing derivation.
- **Reused existing infrastructure**: The dynamic service generated the same `.netdev`
  and `.network` unit files that NixOS normally writes to `/etc/`, just placed in
  `/run/systemd/network/` for volatility. This meant systemd-networkd handled them
  identically.
- **Type safety**: The `types.either base.type dynType` pattern preserved type checking
  for both static values and dynamic references.
- **Minimal runtime dependencies**: Only `bash` and `envsubst` were needed at runtime.

### Weaknesses

- **Incomplete cleanup**: The TODO on line 857 noted that stopping the service removed
  the config files but didn't clean up the actual network interfaces — systemd-networkd
  would "abandon" them.
- **Coarse granularity**: The TODO on line 826 suggested making one service per dynamic
  device rather than a single service for all dynamic topology. As implemented,
  restarting the service regenerated ALL dynamic interfaces even if only one changed.
- **Environment file as interface**: Using a flat environment file for dynamic values
  is simple but fragile — no schema validation, easy to have mismatches between expected
  variable names and what the file provides.
- **Two-phase resolution**: Dynamic values went through an awkward path:
  Nix eval (produces `$VAR_NAME` literal in template) -> envsubst (resolves to actual
  value). This made it harder to reason about what the final configuration would look
  like.
- **No automatic DNS polling**: The system required an external mechanism to update the
  environment file when DNS changed. The endpoint refresh service could re-resolve via
  `wg set`, but the networkd config files themselves would remain stale until the dynamic
  service was restarted.

### What the Current router6 Module Lacks

The current `router6` module (as of the rewrite) has no equivalent of:

- `dynamic.topology` — all topology values must be static at Nix evaluation time
- `dynamicEndpointRefreshRestartSeconds` — no automatic WireGuard endpoint re-resolution
- `from-dynamic` / `mkDynamicOpt` — no type-level support for runtime variable references
- `router-network-dynamic.service` — no runtime generation of networkd units
- `router-wireguard-dynamic-endpoint-refresh` — no handshake staleness monitoring

The current WireGuard configuration (e.g., `wg-ba` and `wg-vpn` on thebeyond) uses
static endpoints or no endpoints (for peers that connect inbound), which works for the
current topology where peer IPs are stable.

## Recommendation for Future Re-implementation

If the dynamic networks feature set is needed again, here is a recommended approach.

**Critical requirement: firewall integration.** Any re-implementation must ensure that
dynamic interfaces are properly integrated with the nftables firewall ruleset. The
original system achieved this by merging dynamic and static topologies at Nix evaluation
time, so firewall rules were generated with the dynamic interface names baked in. A
re-implementation needs a similar mechanism — the router6 zone model needs to know about
dynamic interfaces so it can generate correct `iifname`/`oifname` rules, zone-based
access control, and NAT/masquerade rules for them.

The nftables interaction also imposes a **service ordering constraint**: if nftables
rules reference interface names literally, those interfaces should exist before nftables
loads. The original implementation solved this by running the dynamic network service
before `network-pre.target`. A re-implementation should either maintain similar ordering
discipline, or use nftables features that tolerate missing interfaces (e.g., wildcard
matches like `iifname "wg-*"`, or nftables sets that can be populated dynamically).

### For dynamic WireGuard endpoint resolution only

**Recommended: Standalone systemd service + timer (outside the router module)**

If the only dynamic aspect is endpoint re-resolution (the interface itself is static
and known at build time, just the remote peer's IP changes), this can be handled
without the full dynamic topology system. The interface name is static and can be in
the normal `router6.topology`, so firewall rules work normally.

1. **Create a `wireguard-endpoint-refresh` module** that accepts a list of
   `{ interface, publicKey, endpoint, staleSeconds }` records.

2. **Use a systemd timer** (every 1-5 minutes) that runs a script to:
   - Check `wg show <interface> latest-handshakes` for each configured peer
   - If the handshake is older than `staleSeconds`, run
     `wg set <interface> peer <publicKey> endpoint <endpoint>`
   - This forces WireGuard to re-resolve the DNS name

3. **Avoid the envsubst/environment-file pattern.** Instead, put the DNS hostname
   directly in the endpoint field and let `wg set` resolve it at runtime. The `wg`
   tool resolves DNS names when `wg set ... endpoint` is called, so there is no need
   for the indirection of environment variables for this use case.

This is simpler, more maintainable, and avoids the complexity of the two-topology
system. The original `router-wireguard-dynamic-endpoint-refresh` service essentially
already did this — it just also happened to share the environment file pattern with
the broader dynamic topology system. Because the interface itself is still declared in
`router6.topology`, the zone/firewall system handles it like any other interface.

### For fully dynamic network interfaces: the drop-in approach (recommended)

If a future scenario requires runtime-variable network configuration beyond just
WireGuard endpoint re-resolution, the **networkd drop-in approach** is the recommended
path. This is significantly simpler than the original two-topology system while
preserving the critical firewall integration property.

#### Core idea: static base + dynamic drop-ins

systemd-networkd reads configuration from three directories with this priority:

1. `/etc/systemd/network/` — highest priority (NixOS-managed, immutable)
2. `/run/systemd/network/` — volatile runtime config
3. `/usr/lib/systemd/network/` — vendor defaults

Crucially, **drop-in directories can exist at any level**, and drop-in files always
take precedence over the main file they extend, regardless of which directory each is
in. So a drop-in at `/run/systemd/network/40-wg-friend.network.d/dynamic.conf` will
override values from the base file at `/etc/systemd/network/40-wg-friend.network`.

This enables a clean split:

- **Static (in `/etc/`, managed by NixOS via `router6.topology`)**: The interface name,
  kind, zone assignment, base network type, and any values known at build time. This is
  what the firewall, zone model, DHCP, and DNS derivations see.
- **Dynamic (in `/run/`, written by a small systemd service)**: Only the specific values
  that change at runtime — an IP address, a route, a DNS server, etc.

#### Filesystem layout example

```
/etc/systemd/network/                         ← NixOS-managed (router6 generates these)
├── 30-wg-friend.netdev                       ← WireGuard device definition
│     [NetDev]
│     Name=wg-friend
│     Kind=wireguard
│     [WireGuard]
│     PrivateKeyFile=/run/secrets/wg-friend-key
│     ListenPort=51820
│     [WireGuardPeer]
│     PublicKey=abc123...
│     AllowedIPs=10.200.0.0/24
│     Endpoint=initial.example.com:51820      ← initial/fallback value
│
├── 40-wg-friend.network                      ← Network config for the interface
│     [Match]
│     Name=wg-friend
│     [Network]
│     Address=10.200.0.1/24                   ← could be overridden dynamically
│     [Route]
│     Destination=10.200.0.0/24

/run/systemd/network/                         ← Dynamic (written at runtime)
├── 40-wg-friend.network.d/
│   └── 50-dynamic.conf                      ← Overrides only the dynamic parts
│         [Network]
│         Address=10.200.0.99/24              ← Updated by external script/service
```

In this layout, the nftables ruleset generated by router6 at build time references
`wg-friend` by name (in `iifname`/`oifname` rules, zone access lists, etc.) because
the interface is declared in `router6.topology`. The dynamic drop-in only changes the
address — the firewall rules don't need to change.

#### Why this is smaller than the original approach

The original dynamic topology system required:

- A parallel type system (`mkDynamicOpt`, `dynType`, `from-dynamic`)
- A second topology section (`cfg.dynamic.topology`)
- A merge operation (`whole-topology`)
- A mutual exclusivity assertion
- A monolithic service that regenerated entire `.netdev` and `.network` files via
  `envsubst`
- Empty netdev/network templates (`empty-netdev`, `empty-network`) for unit rendering

The drop-in approach requires **none of this**. The integration with router6 would be:

1. **Declare the interface normally in `router6.topology`** — with its zone, network
   type, and whatever static values are known. Router6 generates the base `.netdev` and
   `.network` files exactly as it does today. Firewall integration is automatic.

2. **Add a small option** (e.g., `router6.topology.<name>.network.dynamicOverrides` or
   a separate `router6.dynamicNetworks` attrset) that specifies which values are
   dynamic and how to resolve them. This could be as simple as a path to a script or a
   set of `{ section, key, environmentVariable }` records.

3. **A single generic systemd service** that, for each interface with dynamic overrides:
   - Reads values from an environment file, a script, or a DNS lookup
   - Writes a small `.conf` drop-in to `/run/systemd/network/<unit>.network.d/`
   - Runs `networkctl reconfigure <interface>` to apply

The router6 module itself doesn't need a second type system or topology merge — it just
needs to know the interface exists (which it does, since it's in the normal topology).

#### Applying changes at runtime

For `.network` file changes (addresses, routes, DNS), `networkctl reconfigure <iface>`
is sufficient and does not disrupt other interfaces:

```bash
# Write the drop-in
mkdir -p /run/systemd/network/40-wg-friend.network.d
cat > /run/systemd/network/40-wg-friend.network.d/50-dynamic.conf <<EOF
[Network]
Address=10.200.0.99/24
EOF

# Apply without restarting all of networkd
networkctl reload          # re-read config files
networkctl reconfigure wg-friend  # apply to specific interface
```

#### Caveats for `.netdev` drop-ins (WireGuard-specific)

There are known systemd bugs that affect `.netdev` drop-ins for WireGuard:

- **Multiple peers in separate drop-in files overwrite each other** instead of creating
  distinct peers ([systemd #18241](https://github.com/systemd/systemd/issues/18241)).
  Peers are keyed by `PublicKey`, but the merging logic is broken for multi-file
  drop-ins.
- **`networkctl reload` does not pick up `.netdev` changes** for WireGuard — the device
  must be deleted and recreated, causing a brief interruption
  ([systemd #25547](https://github.com/systemd/systemd/issues/25547)).
- **Restarting systemd-networkd resets learned WireGuard endpoints**
  ([systemd #21877](https://github.com/systemd/systemd/issues/21877)).

Because of these bugs, **do not use `.netdev` drop-ins for WireGuard peer endpoint
changes**. Instead, use the `wg set` approach described in the "endpoint resolution
only" section above. This is the same approach the original system used in its
`router-wireguard-dynamic-endpoint-refresh` service.

For non-WireGuard `.netdev` changes (e.g., VLAN tags, bridge membership), drop-ins may
work but should be tested against the specific systemd version in use.

#### Combined approach for WireGuard with dynamic endpoints

For the common case (WireGuard interface where the peer endpoint changes), combine both
strategies:

1. **Declare the full interface in `router6.topology`** — zone, addresses, peers, etc.
   NixOS writes the `.netdev` (with initial/fallback endpoint) and `.network` to `/etc/`.
   Firewall rules are generated normally.

2. **Use `.network` drop-ins in `/run/`** for any dynamic network-layer changes (IP
   addresses, routes, DNS).

3. **Use `wg set` via a timer service** for WireGuard endpoint re-resolution — this
   bypasses the buggy `.netdev` drop-in path entirely and works reliably.

This gives you:

- Firewall integration (interface in topology → zone rules generated)
- Dynamic IP/route changes (`.network` drop-ins → `networkctl reconfigure`)
- Dynamic WireGuard endpoints (`wg set` → no networkd restart needed)
- No parallel type system, no topology merge, no envsubst templates

#### Service ordering with nftables

Because the interface is declared in the normal `router6.topology`, NixOS generates its
`.netdev` file in `/etc/` at activation time. systemd-networkd creates the interface
during normal boot, before nftables loads — just like any other static interface. The
dynamic drop-in only changes `.network`-level properties (addresses, routes) after the
interface already exists, so there is no ordering conflict with nftables.

If a future use case involves interfaces that are truly created at runtime (not just
reconfigured), the nftables ordering issue returns. In that case, either:

- Ensure the creation service runs `Before=nftables.service`, or
- Use nftables constructs that tolerate missing interfaces (wildcard patterns like
  `iifname "wg-*"`, or dynamically-populated named sets)

#### Per-interface services

Address the original TODO — create one dynamic service per interface rather than a
single monolithic service, so that changes to one interface don't require regenerating
all dynamic interfaces. With the drop-in approach this is natural: each interface gets
its own small service that manages its own drop-in directory.

### For the use case that originally motivated this (friends with dynamic IPs)

If this is specifically about maintaining WireGuard tunnels to peers on residential
connections with changing IPs, consider **Headscale** (already on the project roadmap
in `llm-notes/headscale-integration-plan.md`). Headscale/Tailscale handles:

- Automatic endpoint discovery and NAT traversal (STUN/DERP)
- Key distribution and rotation
- Connection re-establishment after IP changes

This would be a more robust solution than manual DNS-based endpoint tracking,
especially for non-technical peers. The headscale integration plan already accounts
for this use case.

## Source Reference

The original implementation can be found at commit `44e73da7`:
https://github.com/mutantmell/dotfiles/blob/44e73da7ba10392c9be0cdaf1c0060f3091ede44/modules/router/default.nix

Key line ranges in that file:

- **Dynamic type system**: lines 14-23 (`mkTopologyOpt`, `mkDynamicOpt`, `dynType`)
- **Dynamic topology option**: lines 429-438 (`dynamic.environmentFile`, `dynamic.topology`)
- **Topology merge**: line 443 (`whole-topology`)
- **`from-dynamic` helper**: line 492
- **WireGuard peer endpoint (dynamic-capable)**: line 247
- **`dynamicEndpointRefreshRestartSeconds` option**: lines 259-264
- **`router-network-dynamic` service**: lines 826-870
- **`router-wireguard-dynamic-endpoint-refresh` service**: lines 872-906
- **Endpoint refresh timer**: lines 907-914
- **Mutual exclusivity assertion**: lines 784-785
