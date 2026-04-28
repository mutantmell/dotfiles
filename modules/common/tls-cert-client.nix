{
  config,
  lib,
  pkgs,
  ...
}: let
  caUrl = "https://basel.internal";
  caRoot = pkgs.mmell.lib.data.pki.root;
in {
  options.tls-cert-client.enable = lib.mkEnableOption "fleet TLS client certificate (auto-renewed via step-ca)";

  config = lib.mkIf config.tls-cert-client.enable {
    users.groups.fleet-tls = {};

    systemd.services.fleet-tls-renew = {
      description = "Renew fleet TLS client certificate";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = pkgs.writeShellScript "fleet-tls-renew" ''
          cert=/var/lib/fleet-tls/client.crt
          key=/var/lib/fleet-tls/client.key
          if [[ ! -f $cert ]]; then
            echo "fleet-tls-renew: $cert not found — run scripts/issue-fleet-certs.sh to provision" >&2
            exit 1
          fi
          ${pkgs.step-cli}/bin/step ca renew --force \
            --ca-url ${caUrl} \
            --root ${caRoot} \
            "$cert" "$key"
          chmod 640 "$key"
          chgrp fleet-tls "$key"
        '';
      };
    };

    systemd.timers.fleet-tls-renew = {
      description = "Fleet TLS certificate renewal";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "6h";
        Persistent = true;
      };
    };

    environment.persistence."/persist".directories = [
      {
        directory = "/var/lib/fleet-tls";
        user = "root";
        group = "fleet-tls";
        mode = "0750";
      }
    ];
  };
}
