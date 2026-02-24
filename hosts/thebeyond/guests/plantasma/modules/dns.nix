{ config, pkgs, ... }:

let
  net = pkgs.mmell.lib.data.network;
  h = net.hosts;
in {
  networking.firewall.allowedUDPPorts = [
    53    # DNS
  ];
  networking.firewall.allowedTCPPorts = [
    53    # DNS
  ];

  # Adguard Home - DNS filtering and ad blocking
  services.adguardhome = {
    enable = true;
    settings = {
      dns = {
        bind_hosts = [ "0.0.0.0" ];  # Listen on all interfaces for DNS
        port = 53;
        upstream_dns = [ "127.0.0.1:5335" ];  # Forward to local Unbound
        bootstrap_dns = [ "127.0.0.1:5335" ];
        # Allow queries from router and local networks
        # The router forwards DNS queries here
        allowed_clients = [
          "127.0.0.1"
          "::1"
          h.thebeyond.ipv4     # thebeyond (router)
          h.plantasma.ipv4     # Self
          h.thebeyond.ipv6     # thebeyond (router IPv6)
          h.plantasma.ipv6     # Self IPv6
        ];
      };
      # Web interface binds to localhost only - accessed via nginx with OAuth
      http = {
        address = "127.0.0.1:3000";
      };
      dhcp = {
        enabled = false;  # DHCP is handled by the router
      };
    };
  };

  # Unbound - recursive DNS resolver
  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = [ "127.0.0.1" ];
        port = 5335;
        access-control = [
          "127.0.0.0/8 allow"
          "::1 allow"
          "0.0.0.0/0 refuse"
        ];
        aggressive-nsec = true;

        # Local DNS zone for .local hostnames
        local-zone = ''"local." static'';
        local-data = [
          ''"local. A ${h.thebeyond.ipv4}"''
        ] ++ net.mkUnboundLocalData [
          "thebeyond" "plantasma" "roer" "legram"
          "remiferia" "erebonia" "ordis" "heimdallr" "trista"
          "ardent" "azoth" "denai" "ymir" "calvard"
        ] ++ [
          # Service aliases — point to reverse proxy (ordis)
          ''"git.local. A ${h.ordis.ipv4}"''
          ''"git.local. AAAA ${h.ordis.ipv6}"''

          # Backward-compat aliases during migration
          ''"yggdrasil.local. A ${h.thebeyond.ipv4}"''
          ''"yggdrasil.local. AAAA ${h.thebeyond.ipv6}"''
          ''"jotunheimr.local. A ${h.remiferia.ipv4}"''
          ''"jotunheimr.local. AAAA ${h.remiferia.ipv6}"''
        ];
      };
      remote-control.control-enable = true;
    };
  };

  environment.systemPackages = with pkgs; [
    bind  # for dig/nslookup debugging
  ];
}
