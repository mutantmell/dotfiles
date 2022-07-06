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

  nix.autoOptimiseStore = true;
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
    #openFirewall = true;
    settings = {
      dns = {
        bind_host = "0.0.0.0";
        bind_hosts = [ "127.0.0.1" "0.0.0.0" ];
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

  services.nginx = {
    enable = true;
    recommendedProxySettings = true;
    virtualHosts."${config.networking.hostName}" = {
      forceSSL = true;
      enableACME = true;

      locations."/adguard".return = "302 /adguard/";
      locations."/adguard/" = {
        proxyPass = "http://127.0.0.1:3000/";
        proxyWebsockets = true;
      };

      #locations."/unifi".return = "302 /unifi/";
      #locations."/unifi/" = {
      #  proxyPass = "https://127.0.0.1:8443";
      #  proxyWebsockets = true;
      #};
      #locations."/unifi/inform" = {
      #  proxyPass = "https://127.0.0.1:8080";
      #};

      locations."/auth" = {
        proxyPass = "http://127.0.0.1:9080";
      };
    };
  };
  environment.etc = {
    "step-ca/data/intermediate_ca.crt" = {
      source = ../../common/data/intermediate_ca.crt;
      mode = "0444";
    };
    "step-ca/data/root_ca.crt" = {
      source = ../../common/data/intermediate_ca.crt;
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
            ip = [ "10.0.10.0/24" "10.1.10.0/24" ];
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
        ];
      };
    };
  };

  system.stateVersion = "22.11";
}
