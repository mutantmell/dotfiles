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
    #
    # Threat model: mTLS authenticates "this is some fleet host" but cannot
    # bind the log stream to a specific host. The `host` label sits inside
    # Loki's protobuf push body, set by the client (fluent-bit modify filter),
    # and nginx can't rewrite it the way it rewrites the URL on the metrics
    # endpoint below. So a compromised fleet host can forge logs labelled as
    # any other host — fire false alerts about a peer, hide its own activity
    # behind another hostname during incident response.
    #
    # Accepted because (a) any compromised host already controls its own SSH
    # host key, can mint x.509 certs as itself, and can write arbitrary logs
    # for its own hostname, so the marginal escalation is "lie about peers"
    # not "code execution"; (b) the fleet is internal. If log-spoofing ever
    # becomes a real concern, run vector/alloy on tharbad as a relay: nginx
    # passes $ssl_client_s_dn_cn in a header, the relay overrides the host
    # label from that header before forwarding to Loki.
    #
    # mTLS still earns its keep here for audit ($ssl_client_s_dn_cn in nginx
    # access logs) and to keep unauthenticated traffic off Loki entirely.
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
