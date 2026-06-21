{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.router6;

  inherit (lib) mkIf concatMapAttrs;

  mkDelegation = name: pd: let
    stateDir = "/run/router6-downstream-pd/${name}";
    configFile = "${stateDir}/kea-dhcp6.json";
    serviceName = "router6-downstream-pd-${name}";

    routeHook = pkgs.writeShellScript "router6-downstream-pd-${name}-route-hook" ''
      export PATH="${lib.makeBinPath [pkgs.coreutils pkgs.iproute2]}"
      set -euo pipefail

      install_routes() {
        if [ "''${LEASES6_SIZE:-0}" -eq 0 ]; then
          return 0
        fi

        for i in $(seq 0 "$((LEASES6_SIZE - 1))"); do
          address_var="LEASES6_AT''${i}_ADDRESS"
          prefix_len_var="LEASES6_AT''${i}_PREFIX_LEN"
          address="''${!address_var:-}"
          prefix_len="''${!prefix_len_var:-}"

          if [ -n "$address" ] && [ -n "$prefix_len" ]; then
            ip -6 route replace "$address/$prefix_len" via "$QUERY6_REMOTE_ADDR" dev "$QUERY6_IFACE_NAME"
          fi
        done
      }

      case "''${1:-}" in
        leases6_committed|leases6_renew|leases6_rebind)
          install_routes
          ;;
        *)
          exit 0
          ;;
      esac
    '';

    renderConfig = pkgs.writeScript "render-router6-downstream-pd-${name}.py" ''
      #!${pkgs.python3}/bin/python3
      import ipaddress
      import json
      import subprocess
      import sys

      SOURCE_INTERFACE = ${builtins.toJSON pd.sourceInterface}
      DOWNSTREAM_INTERFACE = ${builtins.toJSON pd.interface}
      LINK_SUBNET6 = ${builtins.toJSON pd.linkSubnet6}
      DELEGATED_LENGTH = ${toString pd.delegatedLength}
      CHILD_INDEX = ${toString pd.childIndex}
      ROUTE_HOOK = ${builtins.toJSON routeHook}
      KEA_RUN_SCRIPT = ${builtins.toJSON "${pkgs.kea}/lib/kea/hooks/libdhcp_run_script.so"}

      def usable(prefix):
          return (
              prefix.version == 6
              and prefix.prefixlen <= DELEGATED_LENGTH
              and prefix.is_global
              and not prefix.is_multicast
              and not prefix.is_link_local
              and not prefix.is_loopback
          )

      def prefix_from_entry(entry):
          if not isinstance(entry, dict):
              return None

          prefix_string = entry.get("PrefixString")
          prefix_length = entry.get("PrefixLength")
          if not isinstance(prefix_string, str):
              return None

          try:
              if prefix_length is None:
                  return ipaddress.ip_network(prefix_string, strict=False)
              return ipaddress.ip_network(f"{prefix_string}/{prefix_length}", strict=False)
          except ValueError:
              return None

      def networkctl_prefixes():
          try:
              text = subprocess.check_output(
                  [
                      "networkctl",
                      "status",
                      SOURCE_INTERFACE,
                      "--json=short",
                      "--no-pager",
                  ],
                  text=True,
              )
          except (OSError, subprocess.CalledProcessError):
              return []

          try:
              status = json.loads(text)
          except json.JSONDecodeError:
              return []

          dhcpv6_client = status.get("DHCPv6Client", {})
          if not isinstance(dhcpv6_client, dict):
              return []

          entries = dhcpv6_client.get("Prefixes", [])
          if not isinstance(entries, list):
              return []

          return [
              prefix
              for prefix in (prefix_from_entry(entry) for entry in entries)
              if prefix is not None and usable(prefix)
          ]

      def current_parent_prefix():
          prefixes = networkctl_prefixes()
          if not prefixes:
              raise RuntimeError(f"no active DHCPv6 delegated prefix found for {SOURCE_INTERFACE}")

          prefixes.sort(key=lambda prefix: prefix.prefixlen)
          max_len = max(prefix.prefixlen for prefix in prefixes)
          candidates = [prefix for prefix in prefixes if prefix.prefixlen == max_len]
          return candidates[-1]

      def downstream_prefix(parent):
          if parent.prefixlen > DELEGATED_LENGTH:
              raise RuntimeError(
                  f"delegated prefix {parent} is too small to split to /{DELEGATED_LENGTH}"
              )
          if parent.prefixlen == DELEGATED_LENGTH:
              if CHILD_INDEX != 0:
                  raise RuntimeError(
                      f"delegated prefix {parent} is already /{DELEGATED_LENGTH}; childIndex must be 0"
                  )
              return parent

          children = list(parent.subnets(new_prefix=DELEGATED_LENGTH))
          if CHILD_INDEX >= len(children):
              raise RuntimeError(
                  f"childIndex {CHILD_INDEX} is outside {parent}'s /{DELEGATED_LENGTH} child range"
              )
          return children[CHILD_INDEX]

      delegated = downstream_prefix(current_parent_prefix())

      config = {
          "Dhcp6": {
              "interfaces-config": {
                  "interfaces": [DOWNSTREAM_INTERFACE],
                  "service-sockets-max-retries": 10,
                  "service-sockets-retry-wait-time": 2000,
              },
              "lease-database": {
                  "type": "memfile",
                  "persist": True,
                  "name": f"/var/lib/kea/router6-downstream-pd-${name}.leases",
              },
              "preferred-lifetime": 3600,
              "valid-lifetime": 7200,
              "renew-timer": 1800,
              "rebind-timer": 3600,
              "subnet6": [
                  {
                      "id": 1,
                      "interface": DOWNSTREAM_INTERFACE,
                      "subnet": LINK_SUBNET6,
                      "pd-pools": [
                          {
                              "prefix": str(delegated.network_address),
                              "prefix-len": delegated.prefixlen,
                              "delegated-len": delegated.prefixlen,
                          }
                      ],
                  }
              ],
              "hooks-libraries": [
                  {
                      "library": KEA_RUN_SCRIPT,
                      "parameters": {
                          "name": ROUTE_HOOK,
                          "sync": False,
                      },
                  }
              ],
              "loggers": [
                  {
                      "name": "kea-dhcp6.router6-downstream-pd.${name}",
                      "output_options": [{"output": "syslog"}],
                      "severity": "INFO",
                  }
              ],
          }
      }

      json.dump(config, sys.stdout, indent=2)
      print()
    '';
  in {
    services = {
      ${serviceName} = {
        description = "Router6 downstream DHCPv6-PD server for ${name}";
        wantedBy = ["multi-user.target"];
        wants = ["systemd-networkd.service"];
        after = ["systemd-networkd.service"];
        path = [pkgs.coreutils pkgs.systemd];
        script = ''
          set -euo pipefail
          install -d -m 0755 ${stateDir} /var/lib/kea
          if [ ! -s ${configFile} ]; then
            ${renderConfig} > ${configFile}
          fi
          exec ${pkgs.kea}/bin/kea-dhcp6 -c ${configFile}
        '';
        serviceConfig = {
          Restart = "on-failure";
          RestartSec = "30s";
          AmbientCapabilities = ["CAP_NET_ADMIN"];
          CapabilityBoundingSet = ["CAP_NET_ADMIN"];
        };
      };

      "${serviceName}-refresh" = {
        description = "Refresh router6 downstream DHCPv6-PD prefix for ${name}";
        after = ["systemd-networkd.service"];
        path = [pkgs.coreutils pkgs.systemd];
        script = ''
          set -euo pipefail
          install -d -m 0755 ${stateDir}
          tmp="$(mktemp ${stateDir}/kea-dhcp6.json.XXXXXX)"
          ${renderConfig} > "$tmp"
          if [ ! -e ${configFile} ] || ! cmp -s "$tmp" ${configFile}; then
            mv "$tmp" ${configFile}
            systemctl try-restart ${serviceName}.service
          else
            rm "$tmp"
          fi
        '';
        serviceConfig.Type = "oneshot";
      };
    };

    timers."${serviceName}-refresh" = {
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitActiveSec = pd.refreshInterval;
        Unit = "${serviceName}-refresh.service";
      };
    };
  };
in {
  config = mkIf cfg.enable {
    systemd.services = concatMapAttrs (name: pd: (mkDelegation name pd).services) cfg.downstreamPrefixDelegations;
    systemd.timers = concatMapAttrs (name: pd: (mkDelegation name pd).timers) cfg.downstreamPrefixDelegations;
  };
}
