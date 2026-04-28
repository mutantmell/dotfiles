{
  pkgs,
  config,
  ...
}: let
  caRoot = pkgs.mmell.lib.data.pki.root;
  lokiPort = config.services.loki.configuration.server.http_listen_port;
  mTLSExtra = ''
    ssl_client_certificate ${caRoot};
    ssl_verify_client on;
  '';
in {
  networking.firewall.allowedTCPPorts = [3100 8427];

  services.nginx.virtualHosts = {
    # Issues and holds the ACME cert for tharbad.internal (shared by push endpoints below).
    "tharbad.internal" = {
      forceSSL = true;
      enableACME = true;
      locations."/" = {
        return = "404";
      };
    };

    # Loki log push endpoint — mTLS only, proxies to local Loki.
    "tharbad-loki-push" = {
      listen = [
        {
          addr = "0.0.0.0";
          port = 3100;
          ssl = true;
        }
      ];
      onlySSL = true;
      useACMEHost = "tharbad.internal";
      extraConfig = mTLSExtra;
      locations."/loki/api/v1/push" = {
        proxyPass = "http://127.0.0.1:${toString lokiPort}";
      };
      locations."/" = {
        return = "404";
      };
    };

    # Metrics push endpoint — mTLS; CN becomes the host extra_label on vmsingle.
    "tharbad-metrics-push" = {
      listen = [
        {
          addr = "0.0.0.0";
          port = 8427;
          ssl = true;
        }
      ];
      onlySSL = true;
      useACMEHost = "tharbad.internal";
      extraConfig = mTLSExtra;
      locations."/api/v1/write" = {
        extraConfig = ''
          proxy_pass http://127.0.0.1:8428/api/v1/write?extra_label=host=$ssl_client_s_dn_cn;
        '';
      };
    };
  };
}
