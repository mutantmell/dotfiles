{ config, pkgs, lib, nixos-hardware, ... }:

{
  imports = [ nixos-hardware.nixosModules.raspberry-pi-4 ];

  nixpkgs.config.allowUnfree = true;

  fileSystems = {
    "/" = {
      device = "/dev/disk/by-label/NIXOS_SD";
      fsType = "ext4";
      options = [ "noatime" ];
    };
  };

  # gpu accelleration
  #hardware.raspberry-pi."4".fkms-3d.enable = true;
  hardware.raspberry-pi."4".poe-hat.enable = true;

  nix.settings.auto-optimise-store = true;
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "-d";
  };
  services.journald.extraConfig = ''
    SystemMaxUse=100M
    MaxFileSec=7day
    Storage=volatile
  '';

  networking.firewall.allowedUDPPorts = [
    53    # DNS
  ];
  networking.firewall.allowedTCPPorts = [ 
    53    # DNS
    80    # HTTP
    443   # HTTPS
    8443  # Unifi
    9443  # ACME (temporary)
  ];

  networking.hostName = "alfheim";
  networking.useDHCP = false;
  networking.interfaces.eth0 = {
    useDHCP = false;
    ipv4.addresses = [{
      address = "10.0.10.2";
      prefixLength = 24;
    }];
  };
  networking.defaultGateway = "10.0.10.1";
  networking.nameservers = [ "10.0.10.1" ]; # use router as main DNS, which will redirect to us for non-mdns
  networking.resolvconf.useLocalResolver = false;
  
  environment.systemPackages = with pkgs; [
    bind
  ];

  services.openssh = {
    enable = true;
    passwordAuthentication = false;
    permitRootLogin = "prohibit-password";
    kbdInteractiveAuthentication = false;
  };
  
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDyEvg2vPwhxg72QgVjNzbzGd3eE0/ZjdoDawHoK24fR malaguy@gmail.com"
  ];

  services.avahi = {
    enable = true;
    publish = {
      enable = true;
      addresses = true;
      userServices = true;
      workstation = true;
    };
  };

  services.unifi = {
    enable = true;
    openFirewall = true;
  };

  services.adguardhome = {
    enable = true;
    settings = {
      dns = {
        #bind_host = "0.0.0.0";
        bind_hosts = [ "0.0.0.0" ];
        upstream_dns = [ "127.0.0.1:5335" ];
        bootstrap_dns = [ "127.0.0.1:5335" ];
        allowed_clients = [ "127.0.0.1" "10.0.10.2" "10.0.10.1" ];
      };
      dhcp = {
        enabled = false;
        gateway_ip = "10.0.10.1";
        subnet_mask = "255.255.255.0";
        range_start = "10.0.10.100";
        range_end = "10.0.10.200";
        lease_duration = 0;
        icmp_timeout_msec = 0;
      };
    };
  };

  services.unbound = {
    enable = true;
    settings = {
      server = {
        interface = [ "127.0.0.1" ];
        port = 5335;
        access-control = [
          "10.0.10.1 allow"
          "10.0.10.2 allow"
          "0.0.0.0/0 refuse"
          "127.0.0.0/8 allow"
          "::1 allow"
        ];
        aggressive-nsec = true;
        local-zone = ''"local." static'';
        local-data = [
          ''"local. A 10.0.10.1"''
          ''"local. AAAA fd00::1"''
          ''"yggdrasil.local. A 10.0.10.1"''
          ''"yggdrasil.local. AAAA fd00::1"''
          ''"alfheim.local. A 10.0.10.2"''
          ''"alfheim.local. AAAA fd00::2"''
        ];
      };
      remote-control.control-enable = true;
    };
  };

  services.keycloak = {
    enable = true;
    settings = {
      http-port = 9080;
      hostname = "alfheim.local";
      http-relative-path = "/auth";
      proxy = "edge";
    };
    database.passwordFile = "/etc/keycloak/data/keycloak_password_file";
  };


  # TODO: add two systemd units that do the following:
  # 1. one that runs after step-ca and before nginx that creates a cert file if not exists as follows:
  #    $ mkdir -p /etc/nginx
  #    $ if [ ! -f /etc/ngnix/<whatever the name is>.crt; then
  #    $ step ca certificate --ca-url=localhost:9443 --root=<some-path> /etc/nginx/blah.1 /etc/nginx.blah.2
  #    $ chown blah blah
  #    $ fi
  # 2. One that runs every day at like 4 AM, renews the cert, and restart nginx
  #    random idea is to all a renewal or something?  or just manually call `systemctl reload nginx` if it's running
  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."${config.networking.hostName}.local" = {
      forceSSL = true;
      enableACME = true;

      locations."/adguard".return = "302 /adguard/";
      locations."/adguard/" = {
        proxyPass = "http://127.0.0.1:3000/";
        proxyWebsockets = true;
      };

      locations."/auth" = {
        proxyPass = "http://127.0.0.1:9080";
      };

      locations."/acme" = {
        proxyPass = "http://127.0.0.1:9443/acme";
#        extraConfig = ''
#          proxy_ssl_certificate /etc/nginx/acme-cert.ca
#          proxy_ssl_certificate_key /etc/nginx/acme-key.ca
#          proxy_ssl_protocols       TLSv1.2 TLSv1.3;
#          proxy_ssl_ciphers         HIGH:!aNULL:!MD5;
#        '';
      };
    };
  };
  environment.etc = {
    "step-ca/data/intermediate_ca.crt" = {
      source = ../../common/data/intermediate_ca.crt;
      mode = "0444";
    };
    "step-ca/data/root_ca.crt" = {
      source = ../../common/data/root_ca.crt;
      mode = "0444";
    };
  };
  security.acme = {
    defaults = {
      server = "https://localhost:9443/acme/acme/directory";
      email = "malaguy@gmail.com";
    };
    acceptTerms = true;
  };
  security.pki.certificates = [ (builtins.readFile ../../common/data/root_ca.crt) ];

  services.step-ca = {
    enable = true;
    address = "0.0.0.0";
    port = 9443;
    openFirewall = true;
    intermediatePasswordFile = "/etc/step-ca/data/intermediate-password-file";
    settings = {
      dnsNames = [ "localhost" "alfheim" "alfheim.local" ];
      root = "/etc/step-ca/data/root_ca.crt";
      crt = "/etc/step-ca/data/intermediate_ca.crt";
      key = "/etc/step-ca/data/intermediate_ca.key";
      db = {
        type = "badger";
        dataSource = "/var/lib/step-ca/db";
      };
      policy = let
        allowLocal = {
          allow = {
            dns = ["*.local"];
            ip = [ "10.0.0.0/16" "10.1.0.0/16" ];
          };
        };
      in {
        x509 = allowLocal;
        ssh.host = allowLocal;
      };
      authority = {
        provisioners = [
          {
            type = "ACME";
            name = "acme";
          }
#          {
#            type = "OIDC";
#            name = "keycloak";
#            clientId = "step-ca";
#            secret = "edsHrbtQizZI2ksicy9p3YnDuuHAYsz6";
#            configurationEndpoint = "https://alfheim.local/auth/realms/SSH/.well-known/openid-configuration";
#            listenAddress = ":10000";
#          }
        ];
      };
    };
  };

  # This setup causes some periodic issues still:
  # acme-alfheim.local fails to renew the cert with the message: Failed with result 'exit-code'
  systemd.services = {
    "acme-alfheim.local".after = [ "step-ca.service" "keycloak.service" ];
    "step-ca".after = [ "keycloak.service" ];
    "keycloak".after = [ "nginx.service" ];
  };

  system.stateVersion = "22.11";
}
