{ config, pkgs, ... }:

{
  networking.firewall.allowedTCPPorts = [ 80 443 ];

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
  security.pki.certificates = [ (builtins.readFile pkgs.mmell.lib.data.certs.root) ];

  services.step-ca = {
    enable = true;
    address = "0.0.0.0";
    port = 9443;
    openFirewall = true;
    intermediatePasswordFile = config.sops.secrets."intermediate-password-file".path;
    settings = {
      dnsNames = [ "localhost" "${config.networking.hostName}" "${config.networking.hostName}.local" ];
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
            ip = [ "10.0.0.0/16" "10.1.0.0/16" "10.97.0.0/16" "fdc6:55f2:0a5e::/48" ];
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

  services.nginx = {
    enable = true;
    recommendedTlsSettings = true;
    recommendedProxySettings = true;

    virtualHosts."${config.networking.hostName}.local" = {
      forceSSL = true;
      enableACME = true;

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

  # ACME self-bootstrap: step-ca issues certs for its own nginx
  security.acme = {
    defaults = {
      server = "https://localhost:9443/acme/acme/directory";
      email = "malaguy@gmail.com";
    };
    acceptTerms = true;
  };

  systemd.services = {
    "acme-${config.networking.hostName}.local" = let
      deps = [ "step-ca.service" ];
    in {
      after = deps;
      requires = deps;
    };
    "nginx".after = [ "step-ca.service" ];
    "nginx".requires = [ "step-ca.service" ];
    "step-ca".before = [ "nginx.service" ];
    "step-ca".requiredBy = [ "nginx.service" ];
  };

  # Bootstrap nginx TLS cert from step-ca (needed before ACME can work)
  systemd.services = {
    "nginx-cert-init" = {
      serviceConfig.Type = "oneshot";
      after = [ "step-ca.service" ];
      requires = [ "step-ca.service" ];
      before = [ "nginx.service" ];
      requiredBy = [ "nginx.service" ];
      path = with pkgs; [ bash step-cli ];
      preStart = ''
        sleep 5
      '';
      script = ''
        #!/usr/bin/env bash

        mkdir -p /etc/nginx
        if [ ! -f /etc/nginx/nginx.cert ]; then
          step ca certificate "${config.networking.hostName}.local" --ca-url=localhost:9443 --root=/etc/step-ca/data/root_ca.crt /etc/nginx/nginx.cert /etc/nginx/nginx.key || exit 1
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

  environment.persistence."/persist" = {
    directories = [
      { directory = "/var/lib/private/step-ca"; user = "step-ca"; group = "step-ca"; }
    ];
  };
}
