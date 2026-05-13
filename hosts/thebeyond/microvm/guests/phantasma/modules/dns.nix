{
  config,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
in {
  networking.firewall.allowedUDPPorts = [
    53 # DNS
  ];
  networking.firewall.allowedTCPPorts = [
    53 # DNS
  ];

  # Blocky owns port 53. NixOS's networkd module defaults
  # services.resolved.enable=true when networkd is on, which binds
  # 127.0.0.53:53 and conflicts with Blocky's 0.0.0.0:53 bind.
  services.resolved.enable = false;

  # Without resolved writing /etc/resolv.conf, point libc-based DNS
  # callers (curl, sops, etc.) at the local Blocky instance.
  networking.nameservers = ["127.0.0.1"];

  # Blocky — declarative DNS proxy with ad-blocking
  services.blocky = {
    enable = true;
    settings = {
      ports = {
        dns = "0.0.0.0:53";
        http = "127.0.0.1:4000"; # metrics + REST API on loopback only
      };

      # Forward all queries to local Unbound (recursive + split-horizon).
      upstreams.groups.default = ["127.0.0.1:5335"];

      # Blocky short-circuits RFC 6761 + ICANN special-use domains
      # (including the recently-added `.internal`) to NXDOMAIN unless they
      # have a conditional upstream. Without this, the entire
      # homelab's `*.internal` and split-horizon `*.mutantmell.net`
      # resolution would break.
      conditional = {
        fallbackUpstream = false;
        mapping = {
          "internal" = "127.0.0.1:5335";
          "internal.mutantmell.net" = "127.0.0.1:5335";
          "mutantmell.net" = "127.0.0.1:5335";
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

  # Unbound - recursive DNS resolver
  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = ["127.0.0.1"];
        port = 5335;
        access-control = [
          "127.0.0.0/8 allow"
          "::1 allow"
          "0.0.0.0/0 refuse"
        ];
        aggressive-nsec = true;

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

  environment.systemPackages = with pkgs; [
    bind # for dig/nslookup debugging
  ];
}
