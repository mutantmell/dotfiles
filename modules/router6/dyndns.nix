{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.router6;
  r6lib = import ./lib.nix {inherit cfg lib;};

  inherit
    (lib)
    concatStringsSep
    filter
    ;
  inherit (builtins) length head;
  inherit (r6lib) flattenTopology;
in {
  config = lib.mkIf (cfg.enable && cfg.dyndns.enable) (let
    inherit (cfg) dyndns;
    dhcpIfaces = filter (i: i.network.type == "dhcp") flattenTopology;
    inferredIface =
      if length dhcpIfaces == 1
      then (head dhcpIfaces).name
      else throw "router6.dyndns: cannot infer external interface (found ${toString (length dhcpIfaces)} DHCP interfaces) — set router6.dyndns.interface explicitly";
    iface =
      if dyndns.interface != null
      then dyndns.interface
      else inferredIface;
    hostsList = concatStringsSep " " (map (h: ''"${h}"'') dyndns.hosts);
  in {
    systemd.services.router6-dyndns = {
      description = "Dynamic DNS updater";
      after = ["network-online.target"];
      wants = ["network-online.target"];
      serviceConfig = {
        Type = "oneshot";
        RuntimeDirectory = "router6-dyndns";
      };
      path = [pkgs.curl pkgs.dig pkgs.gnugrep pkgs.iproute2];
      script =
        if dyndns.protocol == "namecheap"
        then ''
          set -euo pipefail

          STATE_DIR="/run/router6-dyndns"
          DDNS_EXTERNAL_IP="$(ip -4 a show ${iface} | grep -Po 'inet \K[0-9.]*' | head -1)"
          DDNS_DOMAIN="${
            if dyndns.domain != null
            then dyndns.domain
            else "$(cat ${dyndns.domainFile})"
          }"
          DDNS_PASSWORD="$(cat ${dyndns.passwordFile})"

          LAST_IP=""
          if [ -f "$STATE_DIR/last-ip" ]; then
            LAST_IP="$(cat "$STATE_DIR/last-ip")"
          fi

          if [ "$DDNS_EXTERNAL_IP" = "$LAST_IP" ]; then
            echo "External IP $DDNS_EXTERNAL_IP unchanged since last run, skipping"
            exit 0
          fi

          ERRORS=0
          for DDNS_HOST in ${hostsList}; do
            DDNS_FQDN="$DDNS_HOST.$DDNS_DOMAIN"
            if [ "$DDNS_HOST" = "@" ]; then
              DDNS_FQDN="$DDNS_DOMAIN"
            fi

            DDNS_DOMAIN_IP="$(dig +short -t A "$DDNS_FQDN" | head -1)" || DDNS_DOMAIN_IP=""
            if [ "$DDNS_EXTERNAL_IP" != "$DDNS_DOMAIN_IP" ]; then
              echo "Updating $DDNS_HOST: $DDNS_DOMAIN_IP -> $DDNS_EXTERNAL_IP"
              RESPONSE="$(curl -sf --get \
                --data-urlencode "host=$DDNS_HOST" \
                --data-urlencode "domain=$DDNS_DOMAIN" \
                --data-urlencode "password=$DDNS_PASSWORD" \
                "${dyndns.server}/update")" || {
                echo "ERROR: curl failed for host $DDNS_HOST" >&2
                ERRORS=$((ERRORS + 1))
                continue
              }
              echo "Response for $DDNS_HOST: $RESPONSE"
            else
              echo "$DDNS_HOST already points to $DDNS_EXTERNAL_IP"
            fi
          done

          if [ "$ERRORS" -eq 0 ]; then
            echo "$DDNS_EXTERNAL_IP" > "$STATE_DIR/last-ip"
          else
            echo "WARNING: $ERRORS host(s) failed to update, not caching IP" >&2
            exit 1
          fi
        ''
        else throw "router6.dyndns: unknown protocol '${dyndns.protocol}'";
    };

    systemd.timers.router6-dyndns = {
      description = "Dynamic DNS update timer";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = dyndns.renewPeriod;
        OnUnitActiveSec = dyndns.renewPeriod;
        RandomizedDelaySec = "5m";
        Unit = "router6-dyndns.service";
      };
    };
  });
}
