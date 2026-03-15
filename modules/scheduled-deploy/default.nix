{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.scheduled-deploy;

  nodeOpts = {name, ...}: {
    options = {
      schedule = lib.mkOption {
        type = lib.types.str;
        example = "Sun 02:00";
        description = "Systemd calendar expression for this node's deployment schedule";
      };

      flakeRef = lib.mkOption {
        type = lib.types.str;
        example = "git+ssh://git@10.97.100.31/var/lib/git/thebeyond-deploy.git#main";
        description = ''
          Git URL of the flake repository for this node. Supports branch
          selection via a #branch suffix.
        '';
      };

      deployNode = lib.mkOption {
        type = lib.types.str;
        default = name;
        description = ''
          The deploy-rs node name to deploy. Defaults to the attribute name.
        '';
      };
    };
  };

  # Parse a git+ssh:// flake URL into its components
  # e.g., "git+ssh://git@host/repo.git#main" -> { url = "ssh://..."; ref = "main"; }
  # e.g., "git+ssh://git@host/repo.git"      -> { url = "ssh://..."; ref = null; }
  parseFlakeRef = flakeRef: let
    stripped = lib.removePrefix "git+" flakeRef;
    parts = lib.splitString "#" stripped;
    url = lib.head parts;
    ref =
      if lib.length parts > 1
      then lib.elemAt parts 1
      else null;
  in {inherit url ref;};
in {
  options.services.scheduled-deploy = {
    enable = lib.mkEnableOption "Automated scheduled deployment via deploy-rs";

    gitAuthorName = lib.mkOption {
      type = lib.types.str;
      default = "scheduled-deploy";
      description = "Git author name for flake.lock update commits";
    };

    gitAuthorEmail = lib.mkOption {
      type = lib.types.str;
      default = "scheduled-deploy@localhost";
      description = "Git author email for flake.lock update commits";
    };

    stateDirectory = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/scheduled-deploy";
      description = "Directory where local checkouts of wrapper flake repos are stored";
    };

    nodes = lib.mkOption {
      type = lib.types.attrsOf (lib.types.submodule nodeOpts);
      default = {};
      example = lib.literalExpression ''
        {
          thebeyond = {
            schedule = "Sun 02:00";
            flakeRef = "git+ssh://git@10.97.100.31/var/lib/git/thebeyond-deploy.git";
          };
        }
      '';
      description = ''
        Attribute set of nodes to deploy on a schedule.
        Each node references a wrapper flake git repo that re-exports the
        dotfiles flake's deploy configuration.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = cfg.nodes != {};
        message = "services.scheduled-deploy.nodes must not be empty when enabled";
      }
    ];

    systemd.services =
      lib.mapAttrs' (
        nodeName: nodeConfig:
          lib.nameValuePair "scheduled-deploy-${nodeName}" {
            description = "Scheduled deployment for ${nodeConfig.deployNode}";
            wants = ["network-online.target"];
            after = ["network-online.target"];

            serviceConfig = {
              Type = "oneshot";
              User = "root";
            };

            environment = {
              GIT_AUTHOR_NAME = cfg.gitAuthorName;
              GIT_AUTHOR_EMAIL = cfg.gitAuthorEmail;
              GIT_COMMITTER_NAME = cfg.gitAuthorName;
              GIT_COMMITTER_EMAIL = cfg.gitAuthorEmail;
            };

            # openssh is needed on PATH for git and deploy-rs SSH connections
            path = [pkgs.openssh];

            script = let
              workDir = "${cfg.stateDirectory}/${nodeName}";
              parsed = parseFlakeRef nodeConfig.flakeRef;
              branchArgs = lib.optionalString (parsed.ref != null) "--branch ${lib.escapeShellArg parsed.ref}";
            in ''
              set -euo pipefail

              echo "========================================="
              echo "Scheduled deployment started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
              echo "Node: ${nodeConfig.deployNode}"
              echo "========================================="

              # Clone on first run, pull on subsequent runs
              if [ ! -d "${workDir}/.git" ]; then
                echo "Cloning ${parsed.url}..."
                mkdir -p "${workDir}"
                ${pkgs.git}/bin/git clone ${branchArgs} "${parsed.url}" "${workDir}"
              fi

              cd "${workDir}"
              echo "Pulling latest changes..."
              ${pkgs.git}/bin/git pull --ff-only

              echo "Updating flake inputs..."
              ${config.nix.package}/bin/nix flake update --flake "${workDir}" --commit-lock-file
              ${pkgs.git}/bin/git push

              echo "Deploying ${nodeConfig.deployNode}..."
              ${pkgs.deploy-rs}/bin/deploy '.#${nodeConfig.deployNode}'

              DEPLOY_TAG="deploy/${nodeConfig.deployNode}/$(date -u +%Y%m%dT%H%M%SZ)"
              echo "Tagging successful deployment: $DEPLOY_TAG"
              ${pkgs.git}/bin/git tag "$DEPLOY_TAG"
              ${pkgs.git}/bin/git push origin "$DEPLOY_TAG"

              echo "========================================="
              echo "Deployment completed successfully: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
              echo "========================================="
            '';

            startLimitBurst = 3;
            startLimitIntervalSec = 3600;
          }
      )
      cfg.nodes;

    systemd.timers =
      lib.mapAttrs' (
        nodeName: nodeConfig:
          lib.nameValuePair "scheduled-deploy-${nodeName}" {
            wantedBy = ["timers.target"];
            timerConfig = {
              OnCalendar = nodeConfig.schedule;
              Persistent = true;
              RandomizedDelaySec = "1h";
            };
          }
      )
      cfg.nodes;
  };
}
