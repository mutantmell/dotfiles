{
  config,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  # messeldam lives in the management zone, so its own zone subnets are the
  # management subnets — used to gate the admin web UI below.
  inherit (net.forHost "messeldam") zone;
  # Trusted (VLAN 20) is also allowed to reach the admin UI for now, to admin
  # lldap from a daily-driver workstation without tunnelling. This widens the
  # mutation surface to all trusted client devices — tighten to a single admin
  # host (or back to management-only) once initial user setup is done.
  trustedZone = net.networks.trusted;
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

  # Declarative seed so the directory is usable from a cold boot with no manual
  # web-UI step: ensures the base groups and the read-only `authelia` bind user
  # exist (password kept in sync with sops). Authelia's startup check binds as
  # this user and exits fatally if it's absent, so authelia-main is ordered
  # after this unit (see authelia.nix). Idempotent — safe to re-run every boot.
  systemd.services.lldap-bootstrap = {
    description = "Seed lldap with base groups and the Authelia bind user";
    after = ["lldap.service"];
    requires = ["lldap.service"];
    wantedBy = ["multi-user.target"];
    path = [pkgs.lldap-cli pkgs.curl];
    # Disable the start-rate limit so a persistent failure keeps the unit in
    # "activating" (retrying) rather than landing in "failed" — which, since
    # Authelia requires it, would otherwise fail the whole boot and (on this
    # microvm) terminate the guest. Retrying-forever stays up and debuggable.
    unitConfig.StartLimitIntervalSec = 0;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      # Retry until lldap's HTTP API is accepting connections.
      Restart = "on-failure";
      RestartSec = 3;
      LoadCredential = [
        "admin-password:${config.sops.secrets."lldap-admin-password".path}"
        "authelia-password:${config.sops.secrets."authelia-ldap-bind-password".path}"
      ];
    };
    script = ''
      set -euo pipefail

      # lldap-cli authenticates to the HTTP API with these on every call.
      export LLDAP_HTTPURL="http://127.0.0.1:17170"
      export LLDAP_USERNAME="admin"
      export LLDAP_PASSWORD="$(cat "$CREDENTIALS_DIRECTORY/admin-password")"
      authelia_pw="$(cat "$CREDENTIALS_DIRECTORY/authelia-password")"

      # Wait for the API to come up (lldap.service started, but the HTTP
      # listener may not be ready the instant the unit goes active).
      for _ in $(seq 1 60); do
        if curl -sf -o /dev/null "$LLDAP_HTTPURL"; then break; fi
        sleep 1
      done

      # Match against a space-normalised list so this works whether lldap-cli
      # prints one name per line or in columns.
      ensure_group() {
        local existing
        existing=" $(lldap-cli group list | tr '\n' ' ') "
        case "$existing" in
          *" $1 "*) ;;
          *) lldap-cli group add "$1" ;;
        esac
      }
      ensure_group admin
      ensure_group media-users
      ensure_group deploy

      users=" $(lldap-cli user list uid | tr '\n' ' ') "
      case "$users" in
        *" authelia "*) lldap-cli user update set authelia password "$authelia_pw" ;;
        *) lldap-cli user add authelia authelia@mutantmell.net -p "$authelia_pw" ;;
      esac

      # Read-only directory access for authentication lookups.
      member=" $(lldap-cli user group list authelia | tr '\n' ' ') "
      case "$member" in
        *" lldap_strict_readonly "*) ;;
        *) lldap-cli user group add authelia lldap_strict_readonly ;;
      esac
    '';
  };

  # Admin web UI, management + trusted zones. security.acme is configured in
  # authelia.nix (defining it here too would conflict). The source allow/deny
  # sits on the "/" location, not server-wide, so the port-80 ACME challenge
  # location stays reachable for basel to validate.
  services.nginx.virtualHosts."ldap.internal" = {
    forceSSL = true;
    enableACME = true;
    locations."/" = {
      proxyPass = "http://127.0.0.1:17170";
      proxyWebsockets = true;
      # Proxy headers come from services.nginx.recommendedProxySettings
      # (host-wide); don't re-set Host here or nginx emits a duplicate.
      extraConfig = ''
        allow ${zone.subnet4};
        allow ${zone.subnet6};
        allow ${trustedZone.subnet4};
        allow ${trustedZone.subnet6};
        deny all;
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
