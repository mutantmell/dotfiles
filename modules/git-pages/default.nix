{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.services.git-pages;
  format = pkgs.formats.toml {};
  configuration = format.generate "git-pages.toml" cfg.settings;
in {
  options.services.git-pages = {
    enable = lib.mkEnableOption "git-pages static site publishing";
    package = lib.mkPackageOption pkgs "git-pages" {};
    settings = lib.mkOption {
      inherit (format) type;
      default = {};
      description = "git-pages TOML settings; do not put credentials here.";
    };
  };
  config = lib.mkIf cfg.enable {
    services.git-pages.settings = {
      server = {
        pages = lib.mkDefault "tcp/127.0.0.1:3080";
        caddy = lib.mkDefault "tcp/127.0.0.1:3081";
        metrics = lib.mkDefault "-";
      };
      storage = {
        type = lib.mkDefault "fs";
        fs.root = lib.mkDefault "/var/lib/git-pages";
      };
    };
    users.users.git-pages = {
      isSystemUser = true;
      group = "git-pages";
    };
    users.groups.git-pages = {};
    systemd.services.git-pages = {
      description = "Git Pages static site publishing";
      wantedBy = ["multi-user.target"];
      wants = ["network-online.target"];
      after = ["network-online.target"];
      environment.SSL_CERT_FILE = "/etc/ssl/certs/ca-certificates.crt";
      serviceConfig = {
        ExecStart = "${lib.getExe cfg.package} -config ${configuration}";
        User = "git-pages";
        Group = "git-pages";
        StateDirectory = "git-pages";
        Restart = "on-failure";
        RestartSec = 5;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        NoNewPrivileges = true;
        PrivateDevices = true;
        RestrictAddressFamilies = ["AF_UNIX" "AF_INET" "AF_INET6"];
      };
    };
  };
}
