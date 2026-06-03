{config, ...}: let
  certDomain = "authelia.internal";
in {
  # Authelia — OIDC provider + nginx auth_request backend. Runs alongside
  # Keycloak during the migration (Phase 1 coexistence): Keycloak keeps serving
  # auth.mutantmell.net while Authelia is reachable on the internal-only
  # authelia.internal vhost. Consumers move over one at a time (Phase 2), then
  # Phase 3 flips auth.mutantmell.net to Authelia and removes Keycloak.
  services.authelia.instances.main = {
    enable = true;

    # All raw secrets stay out of the nix store. Authelia reads these as the
    # authelia-main system user, so plain 0400 sops secrets owned by that user
    # work directly (no DynamicUser indirection needed here).
    secrets = {
      jwtSecretFile = config.sops.secrets."authelia-jwt-secret".path;
      storageEncryptionKeyFile = config.sops.secrets."authelia-storage-encryption-key".path;
      oidcHmacSecretFile = config.sops.secrets."authelia-oidc-hmac-secret".path;
      # The module turns this into the signed JWKS for OIDC tokens and enables
      # the config template filter automatically.
      oidcIssuerPrivateKeyFile = config.sops.secrets."authelia-oidc-issuer-private-key".path;
    };

    environmentVariables = {
      # lldap bind password for the uid=authelia service account.
      AUTHELIA_AUTHENTICATION_BACKEND_LDAP_PASSWORD_FILE =
        config.sops.secrets."authelia-ldap-bind-password".path;
    };

    # OIDC client definitions carry hashed client secrets, so they're rendered
    # from sops rather than baked into the store. Merges with the module's
    # generated jwks config under identity_providers.oidc.
    settingsFiles = [config.sops.templates."authelia-oidc-clients.yml".path];

    settings = {
      theme = "light";
      server = {
        address = "tcp://127.0.0.1:9091/";
        # Required for nginx auth_request (Phase 2b/2e). Harmless before then.
        endpoints.authz.auth-request.implementation = "AuthRequest";
      };
      log = {
        level = "info";
        format = "json"; # promtail/Loki-friendly (follow-up F2)
      };

      authentication_backend = {
        refresh_interval = "1m";
        # lldap owns password management; Authelia never resets passwords and
        # there is no SMTP notifier wired up for it.
        password_reset.disable = true;
        ldap = {
          implementation = "lldap";
          address = "ldap://127.0.0.1:3890";
          base_dn = "dc=mutantmell,dc=net";
          user = "uid=authelia,ou=people,dc=mutantmell,dc=net";
          # password supplied via the _FILE env var above
        };
      };

      # Coexistence cookie domain: protects *.internal services via the
      # authelia.internal portal. Phase 3 adds a mutantmell.net cookie and
      # switches the portal to auth.mutantmell.net.
      session.cookies = [
        {
          domain = "internal";
          authelia_url = "https://${certDomain}";
        }
      ];

      storage.local.path = "/var/lib/authelia-main/db.sqlite3";
      notifier.filesystem.filename = "/var/lib/authelia-main/notification.txt";

      access_control = {
        default_policy = "deny";
        rules = [
          {
            domain = certDomain;
            policy = "bypass";
          }
          # Admin UIs. Stays one_factor until MFA enrollment lands (follow-up
          # F1), which upgrades admin domains to two_factor.
          {
            domain = "phantasma.internal";
            policy = "one_factor";
            subject = ["group:admin"];
          }
        ];
      };
    };
  };

  # OIDC clients rendered from sops. The client_secret values are pbkdf2-sha512
  # *hashes* (Authelia stores the hash, the consumer holds the plaintext); see
  # sops.nix for how the operator generates them.
  sops.templates."authelia-oidc-clients.yml" = {
    owner = "authelia-main";
    content = ''
      identity_providers:
        oidc:
          clients:
            - client_id: step-ca
              client_name: "SSH Certificate CA"
              client_secret: "${config.sops.placeholder."authelia-oidc-step-ca-secret-hash"}"
              public: false
              authorization_policy: one_factor
              redirect_uris:
                - "http://127.0.0.1:10000"
              scopes: [openid, profile, email, groups]
              grant_types: [authorization_code]
              response_types: [code]
              token_endpoint_auth_method: client_secret_basic
            - client_id: perses
              client_name: "Perses Monitoring"
              client_secret: "${config.sops.placeholder."authelia-oidc-perses-secret-hash"}"
              public: false
              authorization_policy: one_factor
              redirect_uris:
                - "https://perses.internal/api/auth/providers/oidc/authelia/callback"
              scopes: [openid, profile, email, groups]
              grant_types: [authorization_code]
              response_types: [code]
              token_endpoint_auth_method: client_secret_basic
    '';
  };

  # TLS for the internal portal, same step-ca ACME path the other *.internal
  # vhosts use (basel issues, step-ca policy already allows *.internal).
  security.acme = {
    defaults = {
      server = "https://basel.internal/acme/acme/directory";
      email = "malaguy@gmail.com";
    };
    acceptTerms = true;
  };

  services.nginx.virtualHosts.${certDomain} = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:9091";
      proxyWebsockets = true;
      extraConfig = ''
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/authelia-main";
      user = "authelia-main";
      group = "authelia-main";
      mode = "0700";
    }
    {
      directory = "/var/lib/acme";
      user = "acme";
      group = "acme";
    }
  ];
}
