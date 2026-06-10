# Blocky ad-blocking resolver, rendered from the router6 topology.
#
# Blocky sits *in front* of kresd (dns.nix), which retreats to a loopback
# backend when this is enabled. Blocky sees real client source IPs and applies
# a per-client blocklist overlay before its own cache, then forwards clean
# queries to kresd. This is the leak-free replacement for the removed
# `sourceRoutes` bypass: a shared cache may only ever hold the *clean* upstream
# answer; blocking is a per-client overlay on top, never a choice of which
# cached upstream to consult.
#
# Per-interface opt-out is `topology.<iface>.network.dnsBlock = false`, which
# maps that interface's client subnet(s) to an empty blocking-group list.
{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.router6;
  r6lib = import ./lib.nix {inherit cfg lib;};

  inherit
    (lib)
    mkIf
    concatStringsSep
    concatMap
    ;
  inherit
    (r6lib)
    flattenTopology
    dnsInterfaces
    getEffectiveAddresses
    partitionAF
    blockingBackendPort
    ;

  blockCfg = cfg.dns.blocking;
  backend = "127.0.0.1:${toString blockingBackendPort}";

  # Client-facing listen addresses: every DNS-serving zone gateway IP that
  # kresd used to bind, plus the router's own loopback so its libc resolves
  # through Blocky like any other client. Blocky's `ports.dns` is a single
  # comma-separated string of `addr:port` entries.
  ifaceListenAddrs =
    concatMap (
      iface: let
        ifaceData = lib.findFirst (i: i.name == iface) null flattenTopology;
        split = partitionAF (
          if ifaceData != null
          then getEffectiveAddresses ifaceData
          else []
        );
      in
        (map (a: "${a.ip}:53") split.v4)
        ++ (map (a: "[${a.ip}]:53") split.v6)
    )
    dnsInterfaces;

  listenAddrs = ["127.0.0.1:53" "[::1]:53"] ++ ifaceListenAddrs;

  # Client subnet CIDR(s) for an interface — the network the clients live on,
  # not the router's host address. Mirrors the Kea subnet derivation: v4 uses
  # the zeroed network address, v6 the `::`-truncated network prefix.
  clientSubnetsOf = iface:
    map (
      a:
        if a.isV6
        then "${a.networkPrefix}/${toString a.prefix}"
        else "${a.networkAddr}/${toString a.prefix}"
    )
    (getEffectiveAddresses iface);

  # Interfaces that have opted out of blocking. Their client subnets are mapped
  # to a sentinel "noblock" group that carries no denylists.
  #
  # Why a named group and not an empty list: Blocky treats an *empty*
  # clientGroupsBlock value as "no group assignment" and falls back to
  # `default` — which re-applies the blocklist (verified in the VM test;
  # dns-consolidation-plan open item #1). Mapping the subnet to a non-empty
  # group-name list (`["noblock"]`) is a real match, so `default` is not used,
  # and the group itself blocks nothing.
  optOutIfaces = lib.filter (i: !(i.network.dnsBlock or true)) flattenTopology;
  optOutSubnets = concatMap clientSubnetsOf optOutIfaces;
  hasOptOut = optOutSubnets != [];
  noblockGroup = "noblock";
  # An empty denylist source backing the sentinel group.
  noblockList = pkgs.writeText "blocky-noblock-empty" "";
  optOutGroups =
    lib.listToAttrs (map (cidr: lib.nameValuePair cidr [noblockGroup]) optOutSubnets);

  conditionalMapping =
    lib.listToAttrs (map (d: lib.nameValuePair d backend) blockCfg.conditionalDomains);
in {
  config = mkIf (cfg.enable && blockCfg.enable) {
    # Blocky binds the zone gateway IPs but — unlike kresd (per-socket
    # `freebind`) and the old Unbound (`ip-freebind`) — has no freebind option,
    # so at cold boot it crash-loops (Restart=on-failure) until networkd
    # assigns those addresses, briefly taking down the network's DNS. Allow
    # nonlocal binds so it binds cleanly regardless of address ordering — the
    # router-wide analog of the freebind kresd already relies on. Scoped to
    # when blocking is enabled (kresd's own per-socket freebind covers the
    # no-Blocky case, so this stays off otherwise).
    boot.kernel.sysctl = {
      "net.ipv4.ip_nonlocal_bind" = 1;
      "net.ipv6.ip_nonlocal_bind" = 1;
    };

    assertions = [
      {
        assertion = lib.all (g: blockCfg.denylists ? ${g}) blockCfg.defaultGroups;
        message =
          "router6.dns.blocking.defaultGroups references group(s) not present "
          + "in denylists: ${concatStringsSep ", " (lib.filter (g: !(blockCfg.denylists ? ${g})) blockCfg.defaultGroups)}";
      }
    ];

    services.blocky = {
      enable = true;
      settings = {
        ports = {
          # Bind the gateway IPs + loopback explicitly. NOT 0.0.0.0/[::] —
          # that would capture the loopback:5335 backend kresd now owns.
          dns = concatStringsSep "," listenAddrs;
          http = "127.0.0.1:4000"; # metrics + REST API, loopback only
        };

        # All clean queries go to kresd on the loopback backend.
        upstreams.groups.default = [backend];

        # Blocky NXDOMAINs RFC 6761 / ICANN special-use suffixes (incl.
        # `.internal`) unless they have a conditional upstream — without this
        # the homelab's split-horizon naming breaks. Forward them to kresd,
        # which holds the authoritative local zones (Piece 2) / forwards them
        # on (Piece 1).
        conditional = {
          fallbackUpstream = false;
          mapping = conditionalMapping;
        };

        blocking = {
          denylists =
            blockCfg.denylists
            // lib.optionalAttrs hasOptOut {${noblockGroup} = [noblockList];};
          clientGroupsBlock =
            {default = blockCfg.defaultGroups;}
            // optOutGroups;
        };

        prometheus.enable = true;

        log = {
          level = "info";
          format = "json";
        };
      };
    };
  };
}
