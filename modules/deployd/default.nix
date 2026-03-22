# Extractable module: deployd container deployment service.
#
# Provides a privileged helper that accepts typed commands over a Unix socket,
# deploys OCI containers as Podman quadlet units with optional Kata isolation,
# and manages an nftables-scoped bridge network + optional Caddy ingress.
#
# No project-specific logic — no hardcoded hostnames, impermanence, or
# auto-discovery. See modules/common/deployd.nix for project wiring.
{
  config,
  pkgs,
  lib,
  options,
  ...
}: let
  cfg = config.deployd;
  inherit (lib) mkOption mkEnableOption types mkIf mkMerge;
  hasKataOption = options ? virtualisation && options.virtualisation ? kata-containers;
in {
  options.deployd = {
    enable = mkEnableOption "deployd container deployment helper";

    package = mkOption {
      type = types.package;
      default = pkgs.mmell.deployd-helper;
      description = "The deployd-helper package to use.";
    };

    registryAllowlist = mkOption {
      type = types.listOf types.str;
      default = [];
      example = ["registry.internal"];
      description = "Permitted OCI registry prefixes. Images not matching any prefix are rejected.";
    };

    hostnameAllowlist = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [".internal"];
      description = "Permitted hostname suffixes for Caddy ingress routes.";
    };

    portRange = {
      min = mkOption {
        type = types.port;
        default = 1024;
        description = "Minimum permitted host port for published container ports.";
      };
      max = mkOption {
        type = types.port;
        default = 65535;
        description = "Maximum permitted host port for published container ports.";
      };
    };

    socketPath = mkOption {
      type = types.str;
      default = "/run/deployd/deployd.sock";
      description = "Path to the Unix domain socket for helper communication.";
    };

    stateDir = mkOption {
      type = types.str;
      default = "/var/lib/deployd";
      description = "Directory for persistent deployd state.";
    };

    auditLogPath = mkOption {
      type = types.str;
      default = "/var/log/deployd/audit.log";
      description = "Path to the append-only audit log.";
    };

    capabilityTokenFile = mkOption {
      type = types.str;
      description = "Path to the file containing the capability token for socket authentication.";
    };

    allowedUid = mkOption {
      type = types.int;
      description = "UID of the deployd API process permitted to connect to the socket.";
    };

    bridge = {
      name = mkOption {
        type = types.str;
        default = "br-deploy";
        description = "Name of the bridge network device for managed containers.";
      };
      subnet = mkOption {
        type = types.str;
        default = "10.100.0.1/24";
        description = "IPv4 subnet address for the bridge network.";
      };
    };

    caddy = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enable Caddy reverse proxy for dynamic ingress management.";
      };
      adminUrl = mkOption {
        type = types.str;
        default = "http://localhost:2019";
        description = "Caddy admin API base URL.";
      };
      serverName = mkOption {
        type = types.str;
        default = "deployd";
        description = "Caddy server name for the dynamic routes server block. Routes are added to /config/apps/http/servers/<serverName>/routes.";
      };
      listenAddress = mkOption {
        type = types.str;
        default = "";
        example = "10.97.11.5";
        description = "Address for Caddy to listen on for HTTPS. Empty disables the listener.";
      };
    };

    kata = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Enforce Kata Containers runtime for all managed containers.";
      };
    };
  };

  config = mkIf cfg.enable (mkMerge [
    # Core: deployd-helper service, bridge, nftables, Podman
    {
      # Container runtime
      virtualisation.containers.enable = true;
      virtualisation.podman.enable = true;

      # nftables required for the container-deploy table
      networking.nftables.enable = true;

      # Bridge network for managed containers
      systemd.network.netdevs."50-${cfg.bridge.name}".netdevConfig = {
        Kind = "bridge";
        Name = cfg.bridge.name;
      };
      systemd.network.networks."50-${cfg.bridge.name}" = {
        matchConfig.Name = cfg.bridge.name;
        networkConfig = {
          Address = [cfg.bridge.subnet];
          ConfigureWithoutCarrier = true;
        };
        linkConfig.ActivationPolicy = "always-up";
      };

      # nftables table scoped to the bridge — only affects br-deploy traffic
      networking.nftables.tables.container-deploy = {
        family = "inet";
        content = ''
          set allowed_ports { type inet_service; }

          chain forward {
            type filter hook forward priority 5; policy accept;

            # Allow container-to-container on the bridge
            iifname "${cfg.bridge.name}" oifname "${cfg.bridge.name}" accept

            # Allow container egress (outbound from bridge)
            iifname "${cfg.bridge.name}" accept

            # Allow established/related connections back to containers
            oifname "${cfg.bridge.name}" ct state established,related accept

            # Allow only permitted ports inbound to containers
            oifname "${cfg.bridge.name}" tcp dport @allowed_ports accept
            oifname "${cfg.bridge.name}" udp dport @allowed_ports accept

            # Drop all other traffic destined to the bridge
            oifname "${cfg.bridge.name}" drop
          }
        '';
      };

      # User and group for the helper
      users.users.deployd-helper = {
        isSystemUser = true;
        group = "deployd-helper";
        description = "deployd privileged helper";
      };
      users.groups.deployd-helper = {};

      # Directory structure
      systemd.tmpfiles.rules = [
        "d /run/containers/systemd 0775 root deployd-helper - -"
        "d /etc/containers/systemd 0775 root deployd-helper - -"
        "d /run/deployd 0750 deployd-helper deployd-helper - -"
        "d ${cfg.stateDir} 0750 deployd-helper deployd-helper - -"
        "d /var/log/deployd 0750 deployd-helper deployd-helper - -"
      ];

      # deployd-helper systemd service
      systemd.services.deployd-helper = {
        description = "deployd privileged helper";
        wantedBy = ["multi-user.target"];
        after = ["network.target" "systemd-networkd.service"];
        requires = ["systemd-networkd.service"];

        environment = {
          DEPLOYD_SOCKET_PATH = cfg.socketPath;
          DEPLOYD_CAPABILITY_TOKEN_FILE = cfg.capabilityTokenFile;
          DEPLOYD_ALLOWED_UID = toString cfg.allowedUid;
          DEPLOYD_REGISTRY_ALLOWLIST = builtins.concatStringsSep "," cfg.registryAllowlist;
          DEPLOYD_HOSTNAME_ALLOWLIST = builtins.concatStringsSep "," cfg.hostnameAllowlist;
          DEPLOYD_PORT_RANGE_MIN = toString cfg.portRange.min;
          DEPLOYD_PORT_RANGE_MAX = toString cfg.portRange.max;
          DEPLOYD_STATE_DIR = cfg.stateDir;
          DEPLOYD_AUDIT_LOG = cfg.auditLogPath;
          DEPLOYD_BRIDGE_NAME = cfg.bridge.name;
          DEPLOYD_NFTABLES_TABLE = "container-deploy";
          DEPLOYD_CADDY_ADMIN_URL = cfg.caddy.adminUrl;
          DEPLOYD_CADDY_SERVER_NAME = cfg.caddy.serverName;
          DEPLOYD_KATA_RUNTIME =
            if cfg.kata.enable
            then "/run/current-system/sw/bin/kata-runtime"
            else "/run/current-system/sw/bin/crun";
          DEPLOYD_SYSTEMCTL_PATH = "/run/current-system/sw/bin/systemctl";
          DEPLOYD_NFT_PATH = "/run/current-system/sw/bin/nft";
        };

        # Read capability token from file into env var at service start
        script = ''
          export DEPLOYD_CAPABILITY_TOKEN="$(cat "$DEPLOYD_CAPABILITY_TOKEN_FILE")"
          exec ${cfg.package}/bin/deployd-helper
        '';

        serviceConfig = {
          User = "deployd-helper";
          Group = "deployd-helper";
          AmbientCapabilities = ["CAP_NET_ADMIN"];
          CapabilityBoundingSet = ["CAP_NET_ADMIN"];
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ReadWritePaths = [
            "/run/containers/systemd"
            "/etc/containers/systemd"
            "/run/deployd"
            cfg.stateDir
            "/var/log/deployd"
          ];
          UMask = "0027";
          RestrictAddressFamilies = ["AF_UNIX" "AF_NETLINK" "AF_INET"];
          RestrictNamespaces = true;
          SystemCallFilter = ["@system-service" "~@privileged"];
        };
      };
    }

    # Kata runtime (optional — only set if nixpkgs provides the option)
    (lib.optionalAttrs hasKataOption (mkIf cfg.kata.enable {
      virtualisation.kata-containers.enable = true;
    }))

    # Caddy ingress (optional)
    (mkIf cfg.caddy.enable {
      services.caddy = {
        enable = true;
        globalConfig = ''
          admin localhost:2019
        '';
        # Minimal config — routes are managed dynamically via admin API.
        # The server block name (default "deployd") is configurable via
        # caddy.serverName. Routes are added to
        # /config/apps/http/servers/<serverName>/routes.
        extraConfig = lib.optionalString (cfg.caddy.listenAddress != "") ''
          ${cfg.caddy.listenAddress}:443 {
            # Placeholder — routes added dynamically by deployd-helper
            respond "Not Found" 404
          }
        '';
      };
    })
  ]);
}
