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
      # auth-file defaults to /var/lib/ntfy-sh/user.db via the NixOS module
      auth-default-access = "deny-all";
    };
  };

  # Create admin user and grant anonymous write to alert topics.
  # Runs as root (+) to read sops secrets; chowns the auth DB afterward.
  # The ntfy CLI reads /etc/ntfy/server.yml (placed by the NixOS module)
  # to find the auth-file path automatically.
  systemd.services.ntfy-sh.serviceConfig.ExecStartPre = let
    setupScript = pkgs.writeShellScript "ntfy-setup" ''
      # Create admin user if not exists (NTFY_PASSWORD for non-interactive use)
      NTFY_PASSWORD="$(cat ${config.sops.secrets."ntfy-admin-password".path})" \
        ${ntfy} user add --ignore-exists --role=admin admin

      # Grant anonymous write to alert topics so alertmanager can post without auth
      ${builtins.concatStringsSep "\n" (map (topic: ''
          ${ntfy} access everyone '${topic}' write-only
        '')
        alertTopics)}

      # Ensure ntfy-sh service can read the auth database (ExecStartPre with +
      # runs as root, but the service uses DynamicUser)
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
