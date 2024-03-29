{ config, pkgs, lib, ... }:

{
  imports = [
    ./sops.nix
  ];

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
  ];

  common.networking = {
    enable = true;
    hostname = "alfheim";
    interface = "eth0";
  };
  networking.resolvconf.useLocalResolver = false;

  common.openssh = {
    enable = true;
    keys = [ "deploy" "home" ];
  };
  
  environment.systemPackages = with pkgs; [
    bind
  ];

  services.adguardhome = {
    enable = true;
    settings = {
      dns = {
        #bind_host = "0.0.0.0";
        bind_hosts = [ "0.0.0.0" ];
        upstream_dns = [ "127.0.0.1:5335" ];
        bootstrap_dns = [ "127.0.0.1:5335" ];
        allowed_clients = [
          "127.0.0.1"
          "10.0.10.2"
          "10.0.10.1"
        ];
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
    database.passwordFile = config.sops.secrets."keycloak_password_file".path;
  };


  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
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
        extraConfig = ''
          proxy_set_header X-Forwarded-For $proxy_protocol_addr;
          proxy_set_header X-Forwarded-Proto $scheme;
          proxy_set_header Host $host;

          proxy_buffer_size   128k;
          proxy_buffers   4 256k;
          proxy_busy_buffers_size   256k;
        '';
      };

      locations."/acme" = {
        proxyPass = "https://127.0.0.1:9443/acme";
        extraConfig = ''
          proxy_ssl_certificate /etc/nginx/nginx.cert;
          proxy_ssl_certificate_key /etc/nginx/nginx.key;
          proxy_ssl_protocols       TLSv1.2 TLSv1.3;
          proxy_ssl_ciphers         HIGH:!aNULL:!MD5;
        '';
      };
    };
  };
  environment.etc = {
    "step-ca/data/intermediate_ca.crt" = {
      source = pkgs.mmell.lib.data.certs.intermediate;
      mode = "0444";
    };
    "step-ca/data/root_ca.crt" = {
      source = pkgs.mmell.lib.data.certs.root;
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
  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];

  services.step-ca = {
    enable = true;
    address = "0.0.0.0";
    port = 9443;
    openFirewall = true;
    intermediatePasswordFile = config.sops.secrets."intermediate-password-file".path;
    settings = {
      dnsNames = [ "localhost" "alfheim" "alfheim.local" ];
      root = "/etc/step-ca/data/root_ca.crt";
      crt = "/etc/step-ca/data/intermediate_ca.crt";
      key = config.sops.secrets."intermediate_ca.key".path;
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
        ];
      };
    };
  };

  # This setup causes some periodic issues still:
  # acme-alfheim.local fails to renew the cert with the message: Failed with result 'exit-code'
  # NGINX seems to be restarting while the acme call is happening?
  systemd.services = {
    "acme-alfheim.local" = let
      deps = [ "step-ca.service" ];
    in {
      wants = deps;
      after = deps;
      requires = deps;
    };
    "step-ca".wantedBy = [ "acme-alfheim.local.service" ];
    "step-ca".before = [ "acme-alfheim.local.service" ];
    "keycloak".wants = [ "nginx.service" ];
  };

  systemd.services = {
    "nginx-cert-init" = {
      serviceConfig.Type = "oneshot";
      after = [ "step-ca.service" ];
      before = [ "nginx.service" ];
      wantedBy = [ "nginx.service" ];
      path = with pkgs; [ bash step-cli ];
      script = ''
        #!/usr/bin/env bash

        mkdir -p /etc/nginx
        if [ ! -f /etc/nginx/nginx.cert ]; then
          step ca certificate "alfheim.local" --ca-url=localhost:9443 --root=/etc/step-ca/data/root_ca.crt /etc/nginx/nginx.cert /etc/nginx/nginx.key || exit 1
          chown nginx:nginx /etc/nginx/nginx.cert /etc/nginx/nginx.key
        fi
      '';
    };
    "nginx-cert-renew" = {
      serviceConfig.Type = "oneshot";
      path = with pkgs; [ bash step-cli ];
      script = ''
        #!/usr/bin/env bash

        step ca renew --force --ca-url=localhost:9443 --root=/etc/step-ca/data/root_ca.crt /etc/nginx/nginx.cert /etc/nginx/nginx.key

        if (systemctl is-active --quiet nginx); then
          systemctl reload nginx
        fi
      '';
    };
  };
  systemd.timers = {
    "nginx-cert-renew" = {
      wantedBy = [ "timers.target" ];
      partOf = [ "nginx-cert-renew.service" ];
      timerConfig = {
        OnCalendar = "*-*-* 00,12:00:00";        
        Unit = "nginx-cert-renew.service";
      };
    };
  };

  system.stateVersion = "23.05";
}
