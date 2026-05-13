{
  config,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  h = net.hosts;
in {
  networking.firewall.allowedUDPPorts = [
    53 # DNS
  ];
  networking.firewall.allowedTCPPorts = [
    53 # DNS
  ];

  # AdGuard owns port 53 here. NixOS's networkd module defaults
  # services.resolved.enable=true when networkd is on, which binds
  # 127.0.0.53:53 and conflicts with AdGuard's 0.0.0.0:53 bind.
  services.resolved.enable = false;

  # Without resolved writing /etc/resolv.conf, point libc-based DNS
  # callers (curl, sops, etc.) at the local AdGuard instance.
  networking.nameservers = ["127.0.0.1"];

  # Adguard Home - DNS filtering and ad blocking
  services.adguardhome = {
    enable = true;
    settings = {
      dns = {
        bind_hosts = ["0.0.0.0"]; # Listen on all interfaces for DNS
        port = 53;
        upstream_dns = ["127.0.0.1:5335"]; # Forward to local Unbound
        bootstrap_dns = ["127.0.0.1:5335"];
        # Allow queries from router and local networks
        # The router forwards DNS queries here
        allowed_clients = [
          "127.0.0.1"
          "::1"
          h.thebeyond.ipv4
          h.phantasma.ipv4
          h.thebeyond.ipv6
          h.phantasma.ipv6
        ];
      };
      # Web interface binds to localhost only - accessed via nginx with OAuth
      http = {
        address = "127.0.0.1:3000";
      };
      dhcp = {
        enabled = false; # DHCP is handled by the router
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
