# cc-sandbox: Claude Code sandbox orchestrator
#
# Runs a daemon that manages sandbox lifecycle (create/teardown/list) via deployd.
# The daemon holds OIDC + Forgejo credentials and is the sole writer of state.
# Image building (nix/skopeo) runs as the calling user via `cc-sandbox rebuild-image`.
{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.services.cc-sandbox;
  pkg = pkgs.mmell.cc-sandbox;
in {
  options.services.cc-sandbox = {
    enable = lib.mkEnableOption "cc-sandbox daemon";

    apiUrl = lib.mkOption {
      type = lib.types.str;
      description = "deployd-api base URL (e.g. https://roer.internal/api/v1)";
    };

    authUrl = lib.mkOption {
      type = lib.types.str;
      description = "Keycloak token endpoint URL";
    };

    registry = lib.mkOption {
      type = lib.types.str;
      description = "Container registry hostname (e.g. creil.internal)";
    };

    forgejoUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${cfg.registry}";
      description = "Forgejo API base URL (defaults to https://<registry>)";
    };

    imageName = lib.mkOption {
      type = lib.types.str;
      default = "deployd/claude-sandbox";
      description = "Image name on the registry (without tag/digest)";
    };

    caCert = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Path to CA certificate for TLS verification";
    };

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = "/home/mutantmell/git/dotfiles";
      description = "Path to the flake for image builds (used by CLI, not daemon)";
    };

    flakeAttr = lib.mkOption {
      type = lib.types.str;
      default = "claude-sandbox-image";
      description = "Flake attribute for the sandbox image (used by CLI, not daemon)";
    };
  };

  config = lib.mkIf cfg.enable {
    # System user for the daemon — restricted, no shell, no home
    users.users.cc-sandbox = {
      isSystemUser = true;
      group = "cc-sandbox";
      description = "cc-sandbox daemon";
    };
    users.groups.cc-sandbox = {};

    # mutantmell needs group access for the Unix socket
    users.users.mutantmell.extraGroups = ["cc-sandbox"];

    # Sops secrets owned by the daemon user
    sops.secrets."cc-sandbox-client-secret" = {
      owner = "cc-sandbox";
      group = "cc-sandbox";
      mode = "0400";
    };
    sops.secrets."cc-sandbox-forgejo-token" = {
      owner = "cc-sandbox";
      group = "cc-sandbox";
      mode = "0400";
    };

    # Note: no impermanence block needed — edith has a persistent XFS root,
    # so /var/lib/cc-sandbox survives reboots without bind-mount persistence.
    # RuntimeDirectory and StateDirectory in serviceConfig handle directory creation.

    # The daemon: restricted PATH (no nix, skopeo, SSH), only HTTP + state
    systemd.services.cc-sandbox = {
      description = "cc-sandbox daemon";
      wantedBy = ["multi-user.target"];
      after = ["network-online.target"];
      wants = ["network-online.target"];

      environment = {
        CC_SANDBOX_SOCKET_PATH = "/run/cc-sandbox/cc-sandbox.sock";
        CC_SANDBOX_STATE_FILE = "/var/lib/cc-sandbox/state.json";
        CC_SANDBOX_AUTH_URL = cfg.authUrl;
        CC_SANDBOX_API_URL = cfg.apiUrl;
        CC_SANDBOX_REGISTRY = cfg.registry;
        CC_SANDBOX_FORGEJO_URL = cfg.forgejoUrl;
        CC_SANDBOX_IMAGE_NAME = cfg.imageName;
        CC_SANDBOX_CA_CERT = cfg.caCert;
        CC_SANDBOX_CLIENT_SECRET_FILE = config.sops.secrets."cc-sandbox-client-secret".path;
        CC_SANDBOX_FORGEJO_TOKEN_FILE = config.sops.secrets."cc-sandbox-forgejo-token".path;
      };

      serviceConfig = {
        # cc-sandbox-daemon wrapper has restricted PATH (python only, no nix/skopeo)
        ExecStart = "${pkg}/bin/cc-sandbox-daemon";
        User = "cc-sandbox";
        Group = "cc-sandbox";
        RuntimeDirectory = "cc-sandbox";
        RuntimeDirectoryMode = "0750";
        StateDirectory = "cc-sandbox";
        StateDirectoryMode = "0750";
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
        RestrictNamespaces = true;
        SystemCallFilter = ["@system-service" "~@privileged"];
      };
    };

    # CLI environment: make cc-sandbox available system-wide with config env vars
    # so `cc-sandbox rebuild-image` and `cc-sandbox create` work without manual env setup.
    environment.systemPackages = [pkg];
    environment.variables = {
      CC_SANDBOX_SOCKET_PATH = "/run/cc-sandbox/cc-sandbox.sock";
      CC_SANDBOX_REGISTRY = cfg.registry;
      CC_SANDBOX_IMAGE_NAME = cfg.imageName;
      CC_SANDBOX_CA_CERT = cfg.caCert;
      CC_SANDBOX_FLAKE_PATH = cfg.flakePath;
      CC_SANDBOX_FLAKE_ATTR = cfg.flakeAttr;
      # Forgejo token for CLI (rebuild-image) is the user's own credential,
      # read from ~/.config/cc-sandbox/forgejo-token by default.
    };
  };
}
