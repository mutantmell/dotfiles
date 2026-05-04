{pkgs, ...}: let
  vhost = "retrom.internal";
in {
  services.retrom = {
    enable = true;
    enableDatabase = true;
    port = 5101;
    settings = {
      content_directories = [
        # All game platforms live under library/games/ as first-level subdirs.
        # Operator creates platform dirs (gba/, snes/, windows/, linux/, etc.)
        # on demand; Retrom surfaces each as a platform.
        {
          path = "/media/library/games";
          storage_type = 2; # CUSTOM
          custom_library_definition = {
            definition = "{library}/{platform}/{gameDir}";
          };
        }
      ];
      # mister/ is a sibling of library/ at /media/mister, outside all scanned
      # roots, so no ignore_patterns entry is needed.
    };
  };

  # Pin Postgres to PG 17 to match Retrom's embedded build target, keeping a
  # future switch to embedded mode a version-migration-free upgrade path.
  services.postgresql.package = pkgs.postgresql_17;

  security.acme.certs."${vhost}".group = "acme-cert";

  services.nginx.virtualHosts."${vhost}" = {
    forceSSL = true;
    enableACME = true;
    # HTTP/2 required so tonic gRPC (desktop client) terminates cleanly.
    # Default nginx listen is HTTP/1.1 only, which breaks gRPC at the proxy.
    http2 = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:5101";
      extraConfig = ''
        proxy_set_header X-Forwarded-Host $host;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
    # Desktop client uses raw tonic gRPC (HTTP/2); route by Content-Type.
    # Fallback if this proves fragile: open 5101/tcp on the trusted VLAN
    # and point the desktop client at oracion:5101 directly.
    locations."= /grpc" = {
      extraConfig = ''
        if ($content_type ~* "application/grpc") {
          grpc_pass grpc://127.0.0.1:5101;
        }
      '';
    };
  };

  environment.persistence."/persist".directories = [
    {
      directory = "/var/lib/retrom";
      user = "retrom";
      group = "retrom";
    }
    {
      directory = "/var/lib/postgresql";
      user = "postgres";
      group = "postgres";
    }
  ];
}
