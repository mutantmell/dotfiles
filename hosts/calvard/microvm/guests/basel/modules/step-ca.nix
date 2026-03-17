{
  config,
  pkgs,
  ...
}: {
  # step-ca serves TLS directly on port 443 without an nginx reverse proxy.
  # Unlike most services, step-ca is a certificate authority — TLS is its core
  # competency. It uses Go's crypto/tls (memory-safe, no Heartbleed-class bugs),
  # making an nginx TLS termination layer unnecessary overhead that adds
  # complexity (bootstrap certs, renewal timers, dual TLS hops).
  networking.firewall.allowedTCPPorts = [80];

  environment.etc = {
    "step-ca/data/intermediate_ca.crt" = {
      source = pkgs.mmell.lib.data.pki.intermediate;
      mode = "0444";
    };
    "step-ca/data/root_ca.crt" = {
      source = pkgs.mmell.lib.data.pki.root;
      mode = "0444";
    };
    "step-ca/templates/ssh/oidc.tpl" = {
      source = ./templates/oidc.tpl;
      mode = "0444";
    };
  };
  security.pki.certificates = [(builtins.readFile pkgs.mmell.lib.data.pki.root)];

  services.step-ca = {
    enable = true;
    address = "0.0.0.0";
    port = 443;
    openFirewall = true;
    intermediatePasswordFile = config.sops.secrets."intermediate-password-file".path;
    settings = {
      dnsNames = ["localhost" "${config.networking.hostName}" "${config.networking.hostName}.internal.mutantmell.net" "${config.networking.hostName}.internal"];
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
            dns = [
              "*.internal.mutantmell.net"
              "*.internal"
              "*.mutantmell.net"
              "mutantmell.net"
            ];
            ip = ["10.97.0.0/16" "fdc6:55f2:0a5e::/48"];
          };
        };
      in {
        x509 = allowLocal;
        ssh.host = allowLocal;
        ssh.user = {
          allow = {
            principals = ["admin" "deploy"];
          };
        };
      };
      authority = {
        ssh = {
          hostKey = config.sops.secrets."ssh_host_ca_key".path;
          userKey = config.sops.secrets."ssh_user_ca_key".path;
        };
        provisioners = [
          {
            type = "ACME";
            name = "acme";
          }
          {
            type = "OIDC";
            name = "keycloak";
            clientID = "step-ca";
            configurationEndpoint = "https://auth.mutantmell.net/realms/homelab/.well-known/openid-configuration";
            listenAddress = "127.0.0.1:10000";
            claims = {
              enableSSHCA = true;
            };
            options = {
              ssh = {
                templateFile = "/etc/step-ca/templates/ssh/oidc.tpl";
              };
            };
          }
        ];
      };
    };
  };

  environment.persistence."/persist" = {
    directories = [
      {
        directory = "/var/lib/private/step-ca";
        user = "step-ca";
        group = "step-ca";
      }
    ];
  };
}
