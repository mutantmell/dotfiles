{pkgs, ...}: let
  # Forge-Authorization is not one of Caddy's automatically redacted headers.
  # Apply this to both access and error logs, including rejected uploads.
  logFormat = ''
    format filter {
      wrap json
      fields {
        request>headers>Forge-Authorization delete
      }
    }
  '';
in {
  imports = [../../../../../../modules/git-pages];

  services.git-pages = {
    enable = true;
    settings = {
      wildcard = [
        {
          domain = "pages.internal";
          clone-url = "https://forgejo.internal/<user>/<project>.git";
          index-repo = "pages";
          authorization = "forgejo";
        }
      ];
      limits.allowed-repository-url-prefixes = ["https://forgejo.internal/"];
    };
  };

  # Caddy acquires individual names on demand through HTTP-01. No wildcard
  # certificate or DNS provider credentials are necessary. The fixed apex is
  # the upload bootstrap endpoint before the first site has been published.
  services.caddy = {
    enable = true;
    email = "malaguy@gmail.com";
    logFormat = "level ERROR\n" + logFormat;
    acmeCA = "https://basel.internal/acme/acme/directory";
    globalConfig = ''
      acme_ca_root ${pkgs.mmell.lib.data.pki.root}
      cert_issuer acme {
        disable_tlsalpn_challenge
      }
      on_demand_tls {
        ask http://127.0.0.1:3083
      }
    '';
    extraConfig = ''
      http://127.0.0.1:3083 {
        bind 127.0.0.1
        @page expression `{query.domain}.matches('^[a-zA-Z0-9-]+[.]pages[.]internal$')`
        handle @page {
          reverse_proxy 127.0.0.1:3081
        }
        respond 403
      }
      https:// {
        log {
          ${logFormat}
        }
        tls {
          on_demand
        }
        @page host *.pages.internal
        handle @page {
          reverse_proxy 127.0.0.1:3080
        }
        respond 404
      }
    '';
    virtualHosts = {
      "forgejo.internal" = {inherit logFormat;};
      "creil.internal" = {inherit logFormat;};
      "pages.internal" = {
        inherit logFormat;
        extraConfig = ''
          # --server pages.internal retains the per-user HTTP Host header.
          reverse_proxy 127.0.0.1:3080
        '';
      };
    };
  };
  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/git-pages";
      user = "git-pages";
      group = "git-pages";
    }
    {
      directory = "/var/lib/caddy";
      user = "caddy";
      group = "caddy";
    }
  ];
}
