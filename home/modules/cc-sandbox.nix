{
  config,
  pkgs,
  lib,
  ...
}: let
  cfg = config.cc-sandbox;
in {
  options.cc-sandbox = {
    enable = lib.mkEnableOption "cc-sandbox CLI";

    apiUrl = lib.mkOption {
      type = lib.types.str;
      description = "deployd-api base URL (e.g. https://roer.internal/api/v1)";
    };

    authBaseUrl = lib.mkOption {
      type = lib.types.str;
      description = "Keycloak realm base URL (e.g. https://auth.example.com/realms/homelab)";
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

    dnsServers = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      example = ["10.97.100.1"];
      description = "DNS server IPs passed to sandbox containers";
    };

    memoryLimit = lib.mkOption {
      type = lib.types.str;
      default = "4g";
      description = "Memory limit per sandbox container";
    };

    cpuLimit = lib.mkOption {
      type = lib.types.str;
      default = "2";
      description = "CPU limit per sandbox container";
    };

    clientId = lib.mkOption {
      type = lib.types.str;
      default = "cc-sandbox";
      description = "OAuth client ID for Keycloak";
    };

    flakePath = lib.mkOption {
      type = lib.types.str;
      default = ".";
      description = "Path to the flake for image builds";
    };

    flakeAttr = lib.mkOption {
      type = lib.types.str;
      default = "claude-sandbox-image";
      description = "Flake attribute for the sandbox image";
    };

    registryUser = lib.mkOption {
      type = lib.types.str;
      default = "cc";
      description = "Registry username for image push (the Forgejo user that owns the token)";
    };

    forgejoTokenFile = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Path to file containing the Forgejo personal access token";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [pkgs.mmell.cc-sandbox];

    xdg.configFile."cc-sandbox/config.json".text = builtins.toJSON {
      inherit (cfg) apiUrl;
      inherit (cfg) authBaseUrl;
      inherit (cfg) registry;
      inherit (cfg) forgejoUrl;
      inherit (cfg) imageName;
      inherit (cfg) caCert;
      dnsServers = builtins.concatStringsSep " " cfg.dnsServers;
      inherit (cfg) memoryLimit;
      inherit (cfg) cpuLimit;
      inherit (cfg) clientId;
      inherit (cfg) flakePath;
      inherit (cfg) flakeAttr;
      inherit (cfg) registryUser;
      inherit (cfg) forgejoTokenFile;
    };
  };
}
