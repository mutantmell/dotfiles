{config, ...}: let
  # The session cookie domain must contain a period — Authelia rejects the
  # bare single-label `internal`. internal.mutantmell.net is the shared parent
  # of every internal host, so it's the valid cookie domain and also covers
  # cross-host auth_request SSO later (Phase 2b/2e). The portal/issuer therefore
  # lives at the FQDN; `authelia.internal` stays a convenience alias, but the
  # canonical issuer URL consumers use is https://${portalHost}.
  portalHost = "authelia.internal.mutantmell.net";
  cookieDomain = "internal.mutantmell.net";
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

      # Skip Authelia's own startup clock-offset probe. It targets a public NTP
      # server, which messeldam's egress filter blocks by design (NTP is
      # gateway-only); the host already syncs time via the gateway, so this
      # check is redundant noise.
      ntp.disable_startup_check = true;

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

      # Coexistence cookie domain: protects *.internal.mutantmell.net services
      # via the FQDN portal. Phase 3 adds a mutantmell.net cookie and switches
      # the portal to auth.mutantmell.net.
      session.cookies = [
        {
          domain = cookieDomain;
          authelia_url = "https://${portalHost}";
        }
      ];

      storage.local.path = "/var/lib/authelia-main/db.sqlite3";
      notifier.filesystem.filename = "/var/lib/authelia-main/notification.txt";

      access_control = {
        default_policy = "deny";
        rules = [
          {
            domain = portalHost;
            policy = "bypass";
          }
          # No auth_request-protected hosts yet. phantasma had the only internal
          # admin UI (AdGuard Home), retired in the blocky migration; its rule
          # was removed with phantasma's proxy stack (Phase 2b). The first
          # auth_request consumer arrives in Phase 2e (langport, external).
          # When MFA enrollment lands (follow-up F1), admin domains added here
          # move to the two_factor policy.
        ];
      };
    };
  };

  # Don't start Authelia until lldap is seeded — its `user` provider startup
  # check binds as uid=authelia and exits fatally if the account isn't there
  # yet. Hard requirement (not just ordering) so a cold boot can't race the
  # seed and crash-loop.
  systemd.services.authelia-main = {
    after = ["lldap-bootstrap.service"];
    requires = ["lldap-bootstrap.service"];
  };

  # OIDC clients rendered from sops. Confidential clients (perses) carry a
  # pbkdf2-sha512 client_secret *hash* (Authelia stores the hash, the consumer
  # holds the plaintext); see sops.nix for how the operator generates them.
  # step-ca is public (no secret) — see the note on its client below.
  sops.templates."authelia-oidc-clients.yml" = {
    owner = "authelia-main";
    content = ''
      identity_providers:
        oidc:
          # Authelia 4.39 stopped putting non-standard claims (groups, email,
          # name, …) in the ID Token by default — they now only appear at the
          # userinfo endpoint unless a claims policy restores them. step-ca reads
          # `.Token.groups` straight from the ID Token JWT (it never calls
          # userinfo), so without this the SSH cert template gets empty
          # principals and every cert-based login is rejected. Keycloak put
          # groups in the ID Token, which is why this only broke on cutover.
          claims_policies:
            with_groups:
              id_token: [groups, email, preferred_username, name]
          clients:
            # step-ca is a native-app / public client. step-cli runs the
            # authorization-code + PKCE flow on a loopback redirect, and step-ca
            # republishes any provisioner client secret via its public
            # /provisioners API (RFC 8252 / BCP 212) — a confidential secret
            # would be exposed by design. So it's a public client with PKCE,
            # matching how Keycloak had it registered (publicClient: true).
            - client_id: step-ca
              client_name: "SSH Certificate CA"
              public: true
              authorization_policy: one_factor
              claims_policy: with_groups
              redirect_uris:
                - "http://127.0.0.1:10000"
              scopes: [openid, profile, email, groups]
              grant_types: [authorization_code]
              response_types: [code]
              token_endpoint_auth_method: none
              require_pkce: true
              pkce_challenge_method: S256
            - client_id: perses
              client_name: "Perses Monitoring"
              client_secret: "${config.sops.placeholder."authelia-oidc-perses-secret-hash"}"
              public: false
              authorization_policy: one_factor
              claims_policy: with_groups
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

  services.nginx.virtualHosts.${portalHost} = {
    forceSSL = true;
    enableACME = true;
    serverAliases = ["authelia.internal"];
    # Proxy headers (Host, X-Real-IP, X-Forwarded-*) come from
    # services.nginx.recommendedProxySettings (set host-wide). Don't re-set Host
    # here: nginx emits both and Authelia's fasthttp parser rejects a request
    # with duplicate Host headers ("too many Host headers" -> 400).
    locations."/" = {
      proxyPass = "http://127.0.0.1:9091";
      proxyWebsockets = true;
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
