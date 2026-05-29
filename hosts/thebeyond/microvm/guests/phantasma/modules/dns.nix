{
  config,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost "phantasma") host;
in {
  networking.firewall.allowedUDPPorts = [
    53 # DNS
  ];
  networking.firewall.allowedTCPPorts = [
    53 # DNS
  ];

  # Blocky binds the externally-routable v4+v6 addresses; Unbound owns
  # 127.0.0.1:53. Result: libc on phantasma resolves directly through
  # Unbound and never depends on Blocky being up. NixOS's networkd
  # module defaults services.resolved.enable=true, which binds
  # 127.0.0.53:53 and (more importantly) rewrites /etc/resolv.conf to
  # point at that stub — both of which we need to keep clear.
  services.resolved.enable = false;

  # libc → 127.0.0.1:53 → Unbound directly (Blocky is on the external
  # IPs only). Keeps system DNS resolvable even if Blocky fails or
  # restarts. Phantasma is a server — bypassing ad-blocking for its
  # own queries is fine.
  networking.nameservers = ["127.0.0.1"];

  # Blocky — declarative DNS proxy with ad-blocking
  services.blocky = {
    enable = true;
    settings = {
      ports = {
        # Bind only the externally-routable addresses (v4 and v6).
        # NOT 0.0.0.0/[::]:53 — that would capture loopback and force
        # phantasma's own libc through Blocky again.
        dns = "${host.ipv4}:53,[${host.ipv6}]:53";
        http = "127.0.0.1:4000"; # metrics + REST API on loopback only
      };

      # Forward all queries to local Unbound (recursive + split-horizon).
      upstreams.groups.default = ["127.0.0.1:53"];

      # Blocky short-circuits RFC 6761 + ICANN special-use domains
      # (including the recently-added `.internal`) to NXDOMAIN unless they
      # have a conditional upstream. Without this, the entire
      # homelab's `*.internal` and split-horizon `*.mutantmell.net`
      # resolution would break.
      conditional = {
        fallbackUpstream = false;
        mapping = {
          "internal" = "127.0.0.1:53";
          "internal.mutantmell.net" = "127.0.0.1:53";
          "mutantmell.net" = "127.0.0.1:53";
        };
      };

      # Source-IP allowlisting is the firewall's job (allowedUDPPorts above).
      # No Blocky-side client allowlist.

      blocking = {
        # Denylist is pinned via flake input (stevenblack-hosts) and
        # exposed as a store path through the mmell overlay. Avoids the
        # bootstrap chicken-and-egg where Blocky tries to resolve the
        # denylist URL through itself before it's ready.
        denylists.ads = ["${pkgs.mmell.stevenblack-hosts}/hosts"];
        clientGroupsBlock.default = ["ads"];
      };

      prometheus.enable = true;

      log = {
        level = "info";
        format = "json";
      };
    };
  };

  # Unbound - recursive DNS resolver. DNSSEC validation is intentionally
  # ON here: this is the recursive resolver in the chain, and the
  # router-side kresd-fragility note in hosts/thebeyond/router.nix is
  # specific to kresd's taupd trust-anchor refresh, not to Unbound.
  services.unbound = {
    enable = true;
    settings = {
      server = {
        # Listen on 127.0.0.1:53 (so libc and Blocky reach Unbound via the
        # default port) and 127.0.0.1:5335 (kept as a readability alias —
        # makes Unbound easy to spot in netstat/logs separate from Blocky).
        interface = ["127.0.0.1" "127.0.0.1@5335"];
        port = 53;
        access-control = [
          "127.0.0.0/8 allow"
          "0.0.0.0/0 refuse"
        ];
        aggressive-nsec = true;

        # Recover quickly from network transitions. Default infra-host-ttl
        # of 900s means a router/uplink flap can blackhole recursion for 15
        # minutes after Unbound marks roots/auths unreachable. 60s keeps
        # the dead-state window short without meaningfully increasing probe
        # traffic on a homelab.
        infra-host-ttl = 60;

        # Cache sized for the whole homelab — Unbound's defaults (4M each)
        # are too tight for a recursive resolver that fronts every device's
        # queries, leading to repeated cold-cache fetches on first-connect.
        msg-cache-size = "64m";
        rrset-cache-size = "128m";

        # Graceful degradation during upstream outages. serve-expired
        # returns cached records past their TTL only when a fresh fetch is
        # actually slow/failing (client-timeout gate), not as a routine
        # optimization. Stale answers are capped at 1 day and tagged with
        # a short reply TTL so clients re-ask once upstream recovers.
        serve-expired = true;
        serve-expired-client-timeout = 1800;
        serve-expired-ttl = 86400;
        serve-expired-reply-ttl = 30;
        prefetch = true;

        # Split-horizon DNS zones
        local-zone = [
          ''"mutantmell.net." transparent'' # split-horizon: local overrides, rest forwarded
          ''"internal.mutantmell.net." static'' # canonical internal: authoritative, never forwards
          ''"internal." static'' # short alias: authoritative, never forwards
        ];
        local-data = let
          registeredHosts = [
            "thebeyond"
            "phantasma"
            "liberl"
            "erebonia"
            "trista"
            "zeiss"
            "azoth"
            "calvard"
            # network gear (OpenWrt) — only arseille is in the registry post phase 0a;
            # remaining mesh APs will be re-added when OpenWrt configs are imported.
            "arseille"
            # calvard guests
            "messeldam"
            "basel"
            "langport"
            "oracion"
            "tharbad"
            "creil"
            "edith"
            # erebonia guests
            "saint-arkh"
            # liberl guests
            "bose"
            # client devices
            "arcus"
          ];
        in
          # Standard host records (<name>.internal.mutantmell.net + <name>.internal)
          net.mkUnboundLocalData registeredHosts
          # Alias records (split-horizon, backward-compat, service aliases)
          # sourced from hostAliases in network.nix
          ++ net.mkUnboundAliasData registeredHosts;
      };
      remote-control.control-enable = true;
    };
  };

  # Ensure Unbound is listening before Blocky starts answering. Without
  # this, Blocky on a cold boot can accept queries while its upstream
  # (127.0.0.1:53) is still being bound by Unbound, producing SERVFAIL
  # bursts for any device that connects in that window. Unbound is
  # Type=notify on NixOS, so After= only releases once it's listening.
  #
  # Also add `After=network-online.target`: Blocky now binds specific
  # external addresses (${host.ipv4}:53 / [${host.ipv6}]:53) instead of
  # 0.0.0.0:53, so the tap interface must be up and the addresses
  # assigned before Blocky's bind() succeeds. Upstream's NixOS module
  # has wants= but not after= for network-online, which leaves a race
  # we'd hit on cold boot before the v6 address leaves tentative.
  systemd.services.blocky = {
    after = ["network-online.target" "unbound.service"];
    wants = ["unbound.service"];
  };

  environment.systemPackages = with pkgs; [
    bind # for dig/nslookup debugging
  ];
}
