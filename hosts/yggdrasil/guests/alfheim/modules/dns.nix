{ config, pkgs, ... }:

{
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
          "10.0.10.1"   # Yggdrasil (router)
          "10.0.10.2"   # Self
          "10.97.10.1"  # Router migration network
          "10.97.10.2"  # Self migration network
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
          # Router
          ''"local. A 10.0.10.1"''
          ''"yggdrasil.local. A 10.0.10.1"''

          # This microVM (DNS)
          ''"alfheim.local. A 10.0.10.2"''

          # Auth server (Gridr on jotunheimr)
          ''"gridr.local. A 10.0.20.30"''

          # NAS
          ''"jotunheimr.local. A 10.0.10.32"''

          # Media host
          ''"muspelheim.local. A 10.0.10.31"''

          # Services in DMZ
          ''"surtr.local. A 10.0.100.40"''
          ''"bragi.local. A 10.0.100.50"''
          ''"njord.local. A 10.0.100.51"''
          ''"hrungnir.local. A 10.0.100.31"''

          # Home automation
          ''"nidavellir.local. A 10.1.20.50"''

          # MicroVMs on HOME network
          ''"skadi.local. A 10.0.20.40"''
          ''"ymir.local. A 10.0.20.41"''

          # Test/dev hosts
          ''"vanaheim.local. A 10.0.10.30"''
        ];
      };
      remote-control.control-enable = true;
    };
  };

  environment.systemPackages = with pkgs; [
    bind  # for dig/nslookup debugging
  ];
}
