# Extractable module: deployd container deployment service.
#
# Provides a helper that accepts typed commands over a vsock-proxied Unix socket,
# deploys OCI containers as Podman quadlet units with optional Kata isolation,
# and manages Caddy ingress routes. Supports isolated bridge mode (default)
# and uplinked bridge mode (veth pair to an existing bridge for zone-level
# network integration).
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

  hasUplink = cfg.bridge.uplink != "";

  # Build Podman network JSON for environment.etc
  podmanNetworkJson = let
    ipamRange =
      {inherit (cfg.bridge) subnet;}
      // lib.optionalAttrs (cfg.bridge.gateway != "") {inherit (cfg.bridge) gateway;}
      // lib.optionalAttrs (cfg.bridge.poolStart != "" && cfg.bridge.poolEnd != "") {
        rangeStart = cfg.bridge.poolStart;
        rangeEnd = cfg.bridge.poolEnd;
      };
  in
    builtins.toJSON {
      cniVersion = "0.4.0";
      inherit (cfg.bridge) name;
      plugins = [
        ({
            type = "bridge";
            bridge = cfg.bridge.name;
            ipam = {
              type = "host-local";
              ranges = [[ipamRange]];
            };
          }
          // (
            if hasUplink
            then {
              # Uplinked: gateway is external (e.g. router), not this bridge
              isGateway = false;
              ipMasq = false;
            }
            else {
              # Isolated: bridge acts as gateway, masquerade for egress
              isGateway = true;
              ipMasq = true;
            }
          ))
        {
          type = "portmap";
          capabilities = {portMappings = true;};
        }
        {type = "firewall";}
        {type = "tuning";}
      ];
    };
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

    vsockHostSocket = mkOption {
      type = types.str;
      description = "Unix socket path cloud-hypervisor proxies guest vsock connections to (e.g. /var/lib/microvms/roer/notify.vsock_7000).";
    };

    vsockDirectoryService = mkOption {
      type = types.str;
      default = "";
      example = "microvm@roer.service";
      description = "Systemd service that creates the vsock socket directory. When set, deployd-vsock-acl is ordered after it, removing the need for a retry loop.";
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


    bridge = {
      name = mkOption {
        type = types.str;
        default = "br-deploy";
        description = "Name of the bridge network for managed containers.";
      };
      uplink = mkOption {
        type = types.str;
        default = "";
        example = "br100";
        description = "Existing bridge to connect to via a veth pair. When set, containers get L2 connectivity to the uplink network and nftables isolation is skipped (zone rules handle security). When empty, the bridge is isolated with nftables forward-chain rules.";
      };
      subnet = mkOption {
        type = types.str;
        default = "10.100.0.0/24";
        description = "IPv4 subnet CIDR for the container network.";
      };
      gateway = mkOption {
        type = types.str;
        default = "";
        description = "Gateway IP for the container network. When empty, defaults to first address in subnet.";
      };
      poolStart = mkOption {
        type = types.str;
        default = "";
        description = "IPAM pool range start. When empty, uses the full subnet.";
      };
      poolEnd = mkOption {
        type = types.str;
        default = "";
        description = "IPAM pool range end. When empty, uses the full subnet.";
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
    # Core: deployd-helper service, Podman, network config
    {
      # Container runtime
      virtualisation.containers.enable = true;
      virtualisation.podman.enable = true;

      # Podman network config (CNI JSON)
      environment.etc."containers/networks/${cfg.bridge.name}.json" = {
        text = podmanNetworkJson;
      };

      # User and group for the helper
      users.users.deployd-helper = {
        isSystemUser = true;
        group = "deployd-helper";
        description = "deployd privileged helper";
      };
      users.groups.deployd-helper = {};
      # Allow cloud-hypervisor (microvm user) to connect to the vsock proxy socket.
      users.users.microvm.extraGroups = ["deployd-helper"];

      # Polkit rule: allow deployd-helper to manage container units via systemctl.
      # Scoped to daemon-reload and unit start/stop only.
      security.polkit.extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (subject.user === "deployd-helper" &&
              (action.id === "org.freedesktop.systemd1.manage-units" ||
               action.id === "org.freedesktop.systemd1.reload-daemon")) {
            return polkit.Result.YES;
          }
        });
      '';

      # Directory structure
      systemd.tmpfiles.rules = [
        "d /run/containers/systemd 0775 root deployd-helper - -"
        "d /etc/containers/systemd 0775 root deployd-helper - -"
        "d /var/log/deployd 0750 deployd-helper deployd-helper - -"
      ];

      # Ensure vsock socket directory has deployd-helper group write (ACL).
      # Retries until the directory exists — handles fresh installs where
      # microvm-install creates the directory after boot.
      systemd.services.deployd-vsock-acl = {
        description = "Set deployd-helper ACL on vsock socket directory";
        after = lib.optional (cfg.vsockDirectoryService != "") cfg.vsockDirectoryService;
        wants = lib.optional (cfg.vsockDirectoryService != "") cfg.vsockDirectoryService;
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.acl}/bin/setfacl -m g:deployd-helper:rwx ${builtins.dirOf cfg.vsockHostSocket}";
        };
      };

      # deployd-helper systemd service
      systemd.services.deployd-helper = {
        description = "deployd privileged helper";
        wantedBy = ["multi-user.target"];
        requires = ["deployd-vsock-acl.service"];
        after = ["network.target" "deployd-vsock-acl.service"];

        environment = {
          DEPLOYD_VSOCK_HOST_SOCKET = cfg.vsockHostSocket;
          DEPLOYD_CAPABILITY_TOKEN_FILE = cfg.capabilityTokenFile;
          DEPLOYD_REGISTRY_ALLOWLIST = builtins.concatStringsSep "," cfg.registryAllowlist;
          DEPLOYD_HOSTNAME_ALLOWLIST = builtins.concatStringsSep "," cfg.hostnameAllowlist;
          DEPLOYD_PORT_RANGE_MIN = toString cfg.portRange.min;
          DEPLOYD_PORT_RANGE_MAX = toString cfg.portRange.max;
          DEPLOYD_AUDIT_LOG = cfg.auditLogPath;
          DEPLOYD_BRIDGE_NAME = cfg.bridge.name;
          DEPLOYD_CADDY_ADMIN_URL = cfg.caddy.adminUrl;
          DEPLOYD_CADDY_SERVER_NAME = cfg.caddy.serverName;
          DEPLOYD_KATA_RUNTIME =
            if cfg.kata.enable
            then "/run/current-system/sw/bin/kata-runtime"
            else "crun";
          DEPLOYD_SYSTEMCTL_PATH = "/run/current-system/sw/bin/systemctl";
        };

        serviceConfig.ExecStart = "${cfg.package}/bin/deployd-helper";

        serviceConfig = {
          User = "deployd-helper";
          Group = "deployd-helper";
          NoNewPrivileges = true;
          ProtectSystem = "strict";
          ReadWritePaths = [
            "/run/containers/systemd"
            "/etc/containers/systemd"
            "/var/log/deployd"
            "/var/lib/microvms"
          ];
          UMask = "0027";
          RestrictAddressFamilies = ["AF_UNIX" "AF_INET"];
          RestrictNamespaces = true;
          SystemCallFilter = ["@system-service" "~@privileged"];
        };
      };
    }

    # Bridge device (always created via systemd-networkd)
    {
      systemd.network.netdevs."50-${cfg.bridge.name}".netdevConfig = {
        Kind = "bridge";
        Name = cfg.bridge.name;
      };
      systemd.network.networks."50-${cfg.bridge.name}" = {
        matchConfig.Name = cfg.bridge.name;
        networkConfig.ConfigureWithoutCarrier = true;
        linkConfig.ActivationPolicy = "always-up";
      };
    }

    # Uplink: veth pair connecting deployd bridge to an existing bridge
    (mkIf hasUplink {
      systemd.network.netdevs."50-veth-deploy" = {
        netdevConfig = {
          Kind = "veth";
          Name = "veth-deploy";
        };
        peerConfig.Name = "veth-deploy-br";
      };

      # veth-deploy end joins the deployd bridge
      systemd.network.networks."50-veth-deploy" = {
        matchConfig.Name = "veth-deploy";
        networkConfig = {
          Bridge = cfg.bridge.name;
          DHCP = "no";
          LinkLocalAddressing = "no";
        };
      };

      # veth-deploy-br end joins the uplink bridge
      systemd.network.networks."50-veth-deploy-br" = {
        matchConfig.Name = "veth-deploy-br";
        networkConfig = {
          Bridge = cfg.bridge.uplink;
          DHCP = "no";
          LinkLocalAddressing = "no";
        };
      };
    })

    # Isolated mode (no uplink): nftables forward-chain isolation
    (mkIf (!hasUplink) {
      networking.nftables.enable = true;

      # Static bridge isolation: block all unsolicited forward-chain traffic
      # to containers. Caddy reaches containers via published ports (host
      # namespace), which bypass the forward chain entirely.
      networking.nftables.tables.container-deploy = {
        family = "inet";
        content = ''
          chain forward {
            type filter hook forward priority 5; policy accept;

            # Allow container-to-container on the bridge
            iifname "${cfg.bridge.name}" oifname "${cfg.bridge.name}" accept

            # Allow container egress (outbound from bridge)
            iifname "${cfg.bridge.name}" accept

            # Allow established/related connections back to containers
            oifname "${cfg.bridge.name}" ct state established,related accept

            # Drop all other traffic destined to the bridge
            oifname "${cfg.bridge.name}" drop
          }
        '';
      };
    })

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
