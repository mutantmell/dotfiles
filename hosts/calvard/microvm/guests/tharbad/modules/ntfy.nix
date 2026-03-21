{
  config,
  pkgs,
  ...
}: let
  authFile = "/var/lib/ntfy-sh/user.db";
  ntfy = "${pkgs.ntfy-sh}/bin/ntfy";
  alertTopics = ["infra-critical" "security" "services" "cicd"];
in {
  services.ntfy-sh = {
    enable = true;
    settings = {
      listen-http = ":2586";
      base-url = "https://ntfy.internal";
      behind-proxy = true;
      auth-file = authFile;
      auth-default-access = "deny-all";
    };
  };

  # Create admin user and grant anonymous write to alert topics.
  # Runs as root (+) to read sops secrets; chowns the auth DB afterward.
  systemd.services.ntfy-sh.serviceConfig.ExecStartPre = let
    setupScript = pkgs.writeShellScript "ntfy-setup" ''
      # Create admin user if not exists
      ${ntfy} user add \
        --auth-file="${authFile}" --role=admin \
        --password="$(cat ${config.sops.secrets."ntfy-admin-password".path})" \
        admin 2>/dev/null || true

      # Grant anonymous write to alert topics so alertmanager can post without auth
      ${builtins.concatStringsSep "\n" (map (topic: ''
          ${ntfy} access --auth-file="${authFile}" everyone '${topic}' write-only
        '')
        alertTopics)}

      # Ensure ntfy-sh service can read the auth database
      chown ntfy-sh:ntfy-sh "${authFile}"
    '';
  in ["+${setupScript}"];

  # nginx reverse proxy — HTTPS for web UI and phone app
  services.nginx.virtualHosts."ntfy.internal" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:2586";
      proxyWebsockets = true;
    };
  };

  environment.persistence."/persist".directories = [
    "/var/lib/private/ntfy-sh"
  ];
}
