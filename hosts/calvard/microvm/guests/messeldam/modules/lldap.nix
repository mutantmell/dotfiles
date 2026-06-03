{
  config,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  # messeldam lives in the management zone, so its own zone subnets are the
  # management subnets — used to gate the admin web UI below.
  inherit (net.forHost "messeldam") zone;
in {
  # lldap — lightweight LDAP directory. Shared source of truth for both
  # Authelia (authentication + group lookup) and, in Phase 2d, Jellyfin
  # (official LDAP plugin).
  #
  # Phase 1 (coexistence): the LDAP port (3890) binds to localhost only — only
  # Authelia (co-located) needs it. Phase 2d rebinds it to messeldam's address
  # and adds the oracion -> messeldam:3890 firewall/forward rules for Jellyfin.
  #
  # The admin web UI binds to localhost too, but is fronted by nginx at
  # https://ldap.internal and restricted to the management zone (see vhost
  # below). The web UI is the only mutation surface (create/delete users,
  # change groups), so it stays off DMZ/external — messeldam does its own L7
  # source filtering because langport (DMZ) can reach it directly.
  services.lldap = {
    enable = true;
    settings = {
      ldap_host = "127.0.0.1";
      ldap_port = 3890;
      http_host = "127.0.0.1";
      http_port = 17170;
      http_url = "https://ldap.internal";

      ldap_base_dn = "dc=mutantmell,dc=net";
      ldap_user_dn = "admin";
      ldap_user_email = "admin@mutantmell.net";

      # Admin password is declarative (sops). "always" reasserts it from the
      # file on each restart, so a UI change can't silently drift the bootstrap
      # account. Only affects the admin account — the authelia/jellyfin bind
      # users and all member accounts are managed through the web UI.
      ldap_user_pass_file = "/run/credentials/lldap.service/admin-password";
      force_ldap_user_pass_reset = "always";
    };
  };

  # lldap runs as a DynamicUser, so its UID isn't known at build time and the
  # 0400 root-owned sops secret can't be chowned to it. systemd credentials
  # bridge the gap: PID1 reads the secret as root and exposes it to the unit
  # under $CREDENTIALS_DIRECTORY (mounted readable only to the service).
  systemd.services.lldap.serviceConfig.LoadCredential = [
    "admin-password:${config.sops.secrets."lldap-admin-password".path}"
  ];

  # Admin web UI, management-zone only. security.acme is configured in
  # authelia.nix (defining it here too would conflict). The source allow/deny
  # sits on the "/" location, not server-wide, so the port-80 ACME challenge
  # location stays reachable for basel to validate.
  services.nginx.virtualHosts."ldap.internal" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:17170";
      proxyWebsockets = true;
      extraConfig = ''
        allow ${zone.subnet4};
        allow ${zone.subnet6};
        deny all;

        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
      '';
    };
  };

  # DynamicUser state lands in /var/lib/private/lldap (with /var/lib/lldap
  # symlinked to it). Holds users.db (SQLite) and the auto-generated
  # jwt_secret_file — the only mutable auth state in the system.
  environment.persistence."/persist".directories = [
    "/var/lib/private/lldap"
  ];
}
