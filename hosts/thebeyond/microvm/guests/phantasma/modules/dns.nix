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
          h.thebeyond.ipv4 # thebeyond (router) — 10.97
          h.thebeyond.ipv4Legacy # thebeyond (router) — 10.0 legacy
          h.phantasma.ipv4 # Self — 10.97
          h.phantasma.ipv4Legacy # Self — 10.0 legacy
          h.thebeyond.ipv6 # thebeyond (router IPv6)
          h.phantasma.ipv6 # Self IPv6
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
        local-data =
          [
            # Bare domain records — gateway (both 10.97 and legacy 10.0)
            ''"internal.mutantmell.net. A ${h.thebeyond.ipv4}"''
            ''"internal.mutantmell.net. A ${h.thebeyond.ipv4Legacy}"''
            ''"internal. A ${h.thebeyond.ipv4}"''
            ''"internal. A ${h.thebeyond.ipv4Legacy}"''
          ]
          ++ net.mkUnboundLocalData [
            "thebeyond"
            "phantasma"
            "roer"
            "legram"
            "remiferia"
            "erebonia"
            "ordis"
            "heimdallr"
            "trista"
            "ardent"
            "azoth"
            "denai"
            "ymir"
            "calvard"
            # calvard guests
            "edith"
            "basel"
            "langport"
            "oracion"
            "tharbad"
            "creil"
            "messeldam"
            # erebonia guests
            "saint-arkh"
            # remiferia guests
            "monrain"
          ]
          ++ [
            # Split-horizon overrides — external names resolve to internal IPs
            # TODO: switch roer→edith, ordis→langport after calvard migration cutover
            ''"auth.mutantmell.net. A ${h.roer.ipv4}"''
            ''"auth.mutantmell.net. A ${h.roer.ipv4Legacy}"''
            ''"auth.mutantmell.net. AAAA ${h.roer.ipv6}"''
            ''"mutantmell.net. A ${h.ordis.ipv4}"''
            ''"mutantmell.net. A ${h.ordis.ipv4Legacy}"''
            ''"mutantmell.net. AAAA ${h.ordis.ipv6}"''

            # Ardent sub-service aliases
            ''"attic.ardent.internal.mutantmell.net. A ${h.ardent.ipv4}"''
            ''"attic.ardent.internal.mutantmell.net. A ${h.ardent.ipv4Legacy}"''
            ''"attic.ardent.internal.mutantmell.net. AAAA ${h.ardent.ipv6}"''
            ''"attic.ardent.internal. A ${h.ardent.ipv4}"''
            ''"attic.ardent.internal. A ${h.ardent.ipv4Legacy}"''
            ''"attic.ardent.internal. AAAA ${h.ardent.ipv6}"''

            # Backward-compat aliases during migration
            ''"yggdrasil.internal.mutantmell.net. A ${h.thebeyond.ipv4}"''
            ''"yggdrasil.internal.mutantmell.net. A ${h.thebeyond.ipv4Legacy}"''
            ''"yggdrasil.internal.mutantmell.net. AAAA ${h.thebeyond.ipv6}"''
            ''"yggdrasil.internal. A ${h.thebeyond.ipv4}"''
            ''"yggdrasil.internal. A ${h.thebeyond.ipv4Legacy}"''
            ''"yggdrasil.internal. AAAA ${h.thebeyond.ipv6}"''
            ''"jotunheimr.internal.mutantmell.net. A ${h.remiferia.ipv4}"''
            ''"jotunheimr.internal.mutantmell.net. A ${h.remiferia.ipv4Legacy}"''
            ''"jotunheimr.internal.mutantmell.net. AAAA ${h.remiferia.ipv6}"''
            ''"jotunheimr.internal. A ${h.remiferia.ipv4}"''
            ''"jotunheimr.internal. A ${h.remiferia.ipv4Legacy}"''
            ''"jotunheimr.internal. AAAA ${h.remiferia.ipv6}"''
          ];
      };
      remote-control.control-enable = true;
    };
  };

  environment.systemPackages = with pkgs; [
    bind # for dig/nslookup debugging
  ];
}
