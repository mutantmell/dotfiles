# Extractable module: deployd container deployment service.
#
# Provides a helper that accepts typed commands over a vsock-proxied Unix socket,
# deploys OCI containers as containerd/nerdctl systemd units with optional Kata
# isolation, and manages Caddy ingress routes. Supports isolated bridge mode
# (default) and uplinked bridge mode (macvlan on an existing interface for
# zone-level network integration).
#
# Container runtime: containerd + nerdctl.
# TODO: Switch back to Podman quadlets when Podman supports kata-containers natively.
# Kata v3 uses the containerd shimv2 protocol, which Podman cannot invoke directly
# (Podman requires an OCI runtime CLI binary). containerd is the only supported
# path for kata v3. Track: https://github.com/kata-containers/kata-containers/issues/722
#
# Privilege model: deployd-helper runs as an unprivileged user.  All root
# operations (writing systemd units, systemctl, nerdctl inspect) are performed
# by a small shell script (deployd-exec) invoked via a restrictive sudo rule.
# The script lives in the Nix store (read-only, immutable).
#
# No project-specific logic — no hardcoded hostnames, impermanence, or
# auto-discovery. See modules/common/deployd.nix for project wiring.
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.deployd;
  inherit (lib) mkOption mkEnableOption types mkIf mkMerge;
  hasUplink = cfg.bridge.uplink != "";

  nerdctlPath = "/run/current-system/sw/bin/nerdctl";
  systemctlPath = "/run/current-system/sw/bin/systemctl";

  # Privileged wrapper script — handles all root operations on behalf of
  # deployd-helper.  Invoked via sudo; the sudoers rule below permits only
  # this exact Nix store path.
  deployd-exec = pkgs.writeShellScript "deployd-exec" ''
    set -euo pipefail

    usage() {
      echo "Usage: deployd-exec <command> <name> [options]" >&2
      exit 1
    }

    # Validate container name: alphanumeric, hyphen, underscore only.
    validate_name() {
      local name="$1"
      if [ -z "$name" ] || ! echo "$name" | grep -qE '^[a-zA-Z0-9][a-zA-Z0-9_-]*$'; then
        echo "invalid container name: $name" >&2
        exit 1
      fi
      if [ ''${#name} -gt 63 ]; then
        echo "container name too long: $name" >&2
        exit 1
      fi
    }

    [ $# -ge 1 ] || usage
    cmd="$1"; shift

    case "$cmd" in
      write-unit)
        [ $# -ge 1 ] || usage
        name="$1"; shift
        validate_name "$name"

        persistent=false
        for arg in "$@"; do
          case "$arg" in
            --persistent) persistent=true ;;
            *) echo "unknown option: $arg" >&2; exit 1 ;;
          esac
        done

        if [ "$persistent" = true ]; then
          dest="/etc/systemd/system/''${name}.service"
        else
          dest="/run/systemd/system/''${name}.service"
        fi

        cat > "$dest"
        ${systemctlPath} daemon-reload
        ;;

      start)
        [ $# -eq 1 ] || usage
        name="$1"
        validate_name "$name"
        ${systemctlPath} start "''${name}.service"
        ;;

      stop)
        [ $# -eq 1 ] || usage
        name="$1"
        validate_name "$name"
        ${systemctlPath} stop "''${name}.service" || true
        ;;

      remove-unit)
        [ $# -eq 1 ] || usage
        name="$1"
        validate_name "$name"
        rm -f "/run/systemd/system/''${name}.service"
        rm -f "/etc/systemd/system/''${name}.service"
        ${systemctlPath} daemon-reload
        ;;

      inspect)
        [ $# -eq 1 ] || usage
        name="$1"
        validate_name "$name"
        ${nerdctlPath} inspect "$name" \
          --format '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}'
        ;;

      *)
        echo "unknown command: $cmd" >&2
        exit 1
        ;;
    esac
  '';
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
        description = "Name of the network for managed containers.";
      };
      uplink = mkOption {
        type = types.str;
        default = "";
        example = "eno1.100";
        description = "Parent interface for macvlan container networking. When set, a macvlan nerdctl network is created on this interface so containers get direct L2 connectivity to the uplink network and nftables isolation is skipped (zone rules handle security). When empty, an isolated bridge network with nftables forward-chain rules is used instead.";
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
    # Core: deployd-helper service, containerd, network config
    {
      # Container runtime: containerd + nerdctl.
      # nerdctl is the Docker-compatible CLI for containerd; kata uses the
      # containerd shimv2 API which nerdctl/containerd support natively.
      virtualisation.containerd.enable = true;
      environment.systemPackages = [pkgs.nerdctl pkgs.cni-plugins];

      # Tell nerdctl where to find CNI plugin binaries.  On NixOS, plugins are
      # in /run/current-system/sw/bin/ alongside all other system packages.
      environment.etc."nerdctl/nerdctl.toml".text = ''
        cni_path = "/run/current-system/sw/bin"
      '';

      # Static CNI conflist for the deployd network.
      # Writing directly to /etc/cni/net.d/ avoids `nerdctl network create`,
      # which doesn't support setting the bridge interface name.  The CNI bridge
      # plugin reuses an existing interface with the given name (created by
      # systemd-networkd in isolated mode, or the macvlan parent in uplink mode).
      environment.etc."cni/net.d/${cfg.bridge.name}.conflist".text = builtins.toJSON (let
        gateway = lib.optional (cfg.bridge.gateway != "") cfg.bridge.gateway;
        ipamRange =
          {inherit (cfg.bridge) subnet;}
          // lib.optionalAttrs (cfg.bridge.gateway != "") {inherit (cfg.bridge) gateway;}
          // lib.optionalAttrs (cfg.bridge.poolStart != "") {rangeStart = cfg.bridge.poolStart;}
          // lib.optionalAttrs (cfg.bridge.poolEnd != "") {rangeEnd = cfg.bridge.poolEnd;};
        ipam = {
          type = "host-local";
          ranges = [[ipamRange]];
          routes = [{dst = "0.0.0.0/0";}];
        };
        mainPlugin =
          if hasUplink
          then {
            type = "macvlan";
            master = cfg.bridge.uplink;
            mode = "bridge";
            inherit ipam;
          }
          else {
            type = "bridge";
            bridge = cfg.bridge.name;
            isGateway = true;
            ipMasq = true;
            inherit ipam;
          };
      in {
        cniVersion = "1.0.0";
        inherit (cfg.bridge) name;
        plugins = [
          mainPlugin
          {
            type = "portmap";
            capabilities.portMappings = true;
          }
        ];
      });

      # User and group for the helper
      users.users.deployd-helper = {
        isSystemUser = true;
        group = "deployd-helper";
        description = "deployd privileged helper";
      };
      users.groups.deployd-helper = {};

      # Sudo rule: deployd-helper can run exactly this Nix store path, nothing else.
      security.sudo = {
        enable = true;
        extraRules = [
          {
            users = ["deployd-helper"];
            commands = [
              {
                command = "${deployd-exec}";
                options = ["NOPASSWD"];
              }
            ];
          }
        ];
      };

      # Directory structure
      systemd.tmpfiles.rules = [
        "d /var/log/deployd 0750 deployd-helper deployd-helper - -"
        # Create vsock socket directory if it does not already exist.
        # In production the directory is created by the microvm service; this
        # ensures it exists in environments without a microvm (e.g. VM tests).
        "d ${builtins.dirOf cfg.vsockHostSocket} 0770 deployd-helper deployd-helper - -"
      ];

      # Ensure vsock socket directory has deployd-helper group write (ACL).
      # This is the only remaining ACL — needed because the microvm service
      # creates the directory as root, and deployd-helper must bind its socket there.
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
        after = [
          "network.target"
          "deployd-vsock-acl.service"
          "containerd.service"
        ];

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
          DEPLOYD_RUNTIME_CLASS =
            if cfg.kata.enable
            then "io.containerd.kata.v2"
            else "io.containerd.runc.v2";
          DEPLOYD_NERDCTL_PATH = nerdctlPath;
          DEPLOYD_EXEC_PATH = "${deployd-exec}";
        };

        path = ["/run/wrappers"]; # sudo lives here on NixOS

        serviceConfig = {
          ExecStart = "${cfg.package}/bin/deployd-helper";
          User = "deployd-helper";
          Group = "deployd-helper";
          ProtectSystem = "strict";
          ReadWritePaths = [
            "/var/log/deployd"
            "/run/systemd/system"
            "/etc/systemd/system"
            (builtins.dirOf cfg.vsockHostSocket)
          ];
          UMask = "0027";
          RestrictAddressFamilies = ["AF_UNIX" "AF_INET"];
          RestrictNamespaces = true;
          # Note: cannot use ~@privileged because sudo (invoked for deployd-exec)
          # needs setuid/setgid syscalls after the setuid exec.
          SystemCallFilter = ["@system-service"];
        };
      };
    }

    # Bridge device (isolated mode only — uplink mode uses macvlan on the
    # uplink interface directly, so no local bridge is needed)
    (mkIf (!hasUplink) {
      systemd.network.netdevs."50-${cfg.bridge.name}".netdevConfig = {
        Kind = "bridge";
        Name = cfg.bridge.name;
      };
      systemd.network.networks."50-${cfg.bridge.name}" = {
        matchConfig.Name = cfg.bridge.name;
        networkConfig.ConfigureWithoutCarrier = true;
        linkConfig.ActivationPolicy = "always-up";
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

            # Block container-to-container lateral movement on the bridge.
            # Per-container rules may be added in Phase D4 for game servers.
            iifname "${cfg.bridge.name}" oifname "${cfg.bridge.name}" drop

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

    # Kata runtime: install kata-runtime (provides containerd-shim-kata-v2),
    # load required kernel modules, create /etc/kata-containers/configuration.toml,
    # and set the containerd service PATH so it can find the shim binary.
    (mkIf cfg.kata.enable {
      environment.systemPackages = [pkgs.kata-runtime];
      boot.kernelModules = ["vhost" "vhost_net" "vhost_vsock" "kvm"];
      environment.etc."kata-containers/configuration.toml".source = "${pkgs.kata-runtime}/share/defaults/kata-containers/configuration-qemu.toml";

      # containerd resolves shim binaries via exec.LookPath, which searches the
      # process's PATH.  Adding kata-runtime to the containerd service path
      # ensures containerd-shim-kata-v2 is discoverable without overriding the
      # NixOS-managed PATH.
      systemd.services.containerd.path = [pkgs.kata-runtime];
    })

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
