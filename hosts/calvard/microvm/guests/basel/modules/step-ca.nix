{
  config,
  lib,
  pkgs,
  ...
}: let
  inherit (pkgs.mmell.lib) data;
  fleetX5cCAExists = data.pki.fleetX5cCA != null;
in {
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
  services.step-ca = {
    enable = true;
    address = "[::]";
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
      ssh = {
        hostKey = config.sops.secrets."ssh_host_ca_key".path;
        userKey = config.sops.secrets."ssh_user_ca_key".path;
      };
      authority = {
        provisioners =
          [
            {
              type = "ACME";
              name = "acme";
              claims = {
                defaultTLSCertDuration = "1080h";
                maxTLSCertDuration = "2160h";
              };
            }
            {
              type = "OIDC";
              name = "authelia";
              clientID = "step-ca";
              # Public client (no clientSecret): step-cli does authorization-code
              # + PKCE on the loopback redirect, and step-ca would publish any
              # secret via its /provisioners API anyway. Matches the public
              # client registered in messeldam's authelia.nix.
              configurationEndpoint = "https://authelia.internal.mutantmell.net/.well-known/openid-configuration";
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
          ]
          ++ (lib.optional fleetX5cCAExists {
            # X5C: fleet hosts self-enroll for x.509 client certs using their
            # pre-signed enrollment cert (signed by the offline fleet_x5c_ca) as the
            # X5C trust anchor. Provisioner activates once fleet_x5c_ca.crt is committed.
            type = "X5C";
            name = "fleet-x5c";
            roots = builtins.readFile (pkgs.runCommand "fleet-x5c-ca-b64" {} ''
              ${pkgs.coreutils}/bin/base64 -w0 ${data.pki.fleetX5cCA} > $out
            '');
            claims = {
              defaultTLSCertDuration = "8760h";
              maxTLSCertDuration = "8760h";
            };
          });
      };
    };
  };

  # Retry OIDC provisioner initialization after boot.
  # step-ca and the OIDC provider (Authelia on messeldam) have a circular
  # dependency: step-ca fetches Authelia's OIDC discovery doc at provisioner
  # init, but Authelia's discovery is served over TLS by nginx using an ACME
  # cert issued by *this* step-ca. So on a cold boot step-ca must serve ACME
  # before Authelia can present a valid cert, before step-ca can complete OIDC
  # discovery. step-ca gracefully degrades (serves ACME with OIDC disabled) so
  # Authelia can get its cert; this service then waits for Authelia to be
  # reachable and restarts step-ca to re-initialize the OIDC provisioner.
  # (This is structural to the ACME chicken-and-egg, not a Keycloak-JVM-speed
  # workaround — it survives the Keycloak->Authelia migration.)
  systemd.services.step-ca-oidc-retry = {
    description = "Retry step-ca OIDC provisioner initialization";
    after = ["step-ca.service"];
    wants = ["step-ca.service"];
    wantedBy = ["multi-user.target"];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = 10;
      RestartMaxDelaySec = 300;
      RestartSteps = 5;
    };
    # Only restart step-ca if OIDC isn't already working.
    # step-ca exposes provisioners at /provisioners — if the authelia
    # provisioner appears, OIDC initialized successfully and no restart is
    # needed.
    script = ''
      # Wait for Authelia to be reachable
      ${pkgs.curl}/bin/curl -sf --max-time 5 \
        https://authelia.internal.mutantmell.net/.well-known/openid-configuration \
        -o /dev/null

      # Check if step-ca already has the OIDC provisioner initialized.
      # The /provisioners endpoint includes a "state" field when a provisioner
      # failed to initialize — only skip restart if authelia has no such field.
      if ${pkgs.curl}/bin/curl -sf --max-time 5 \
        https://localhost:443/provisioners 2>/dev/null \
        | ${pkgs.jq}/bin/jq -e '.provisioners[] | select(.name == "authelia") | has("state") | not' \
        >/dev/null 2>&1; then
        echo "OIDC provisioner already initialized, skipping restart"
        exit 0
      fi

      echo "OIDC provisioner not loaded, restarting step-ca"
      ${pkgs.systemd}/bin/systemctl restart step-ca
    '';
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
