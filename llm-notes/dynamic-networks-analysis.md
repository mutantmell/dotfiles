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

### For fully dynamic network interfaces (non-WireGuard)

If a future scenario requires runtime-variable network interfaces beyond just WireGuard
endpoint re-resolution (e.g., an interface whose IP address or configuration changes at
runtime based on external input), consider:

1. **Declare the interface in `router6.topology` even if it's dynamic.** The key
   insight from the original design is that the interface must be in the topology for
   firewall rules to be generated. Even if the networkd configuration files are
   generated at runtime, the interface name and zone assignment should be declared
   statically so that nftables rules, zone access control, and NAT rules include it.
   This is what the original `whole-topology` merge achieved.

2. **systemd-networkd drop-in directories**: Write dynamic configuration as drop-in
   overrides in `/run/systemd/network/<unit>.d/` rather than replacing the entire unit
   file. This allows the base configuration to be managed by NixOS normally while only
   the variable portions are handled dynamically.

3. **`networkctl reload`**: After writing dynamic config files, use `networkctl reload`
   (or `networkctl reconfigure <interface>`) rather than relying on service ordering
   relative to `network-pre.target`. This allows updating configurations without
   requiring a full network restart.

4. **Service ordering with nftables**: If using `networkctl reload` instead of
   pre-`network-pre.target` ordering, ensure that nftables rules are loaded after
   dynamic interfaces are created, or use nftables constructs that tolerate missing
   interfaces. The router6 module's nftables generation would need to account for this.

5. **Per-interface services**: Address the original TODO — create one dynamic service
   per interface rather than a single monolithic service, so that changes to one
   interface don't require regenerating all dynamic interfaces.

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
