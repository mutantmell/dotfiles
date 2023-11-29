{ config, options, pkgs, lib, ... }:

let
  cfg = config.common.zfs;
in {
  options.common.zfs = {
    enable = lib.mkEnableOption "Enable common ZFS options";
    remoteUnlock = lib.mkOption {
      type = lib.types.submodule {
        options.enable = lib.mkEnableOption "Remote Unlock via SSH";
        options.hostkey = lib.mkOption {
          type = lib.types.path;
          default = /etc/ssh/initrd_ssh_host_ed25519_key;
        };
      };
      default = {};
    };
    impermanence = lib.mkOption {
      type = lib.types.submodule {
        options.enable = lib.mkEnableOption "Impermanence common options";
        options.dataset = lib.mkOption {
          type = lib.types.str;
          description = "zfs dataset to rollback on boot";
        };
        options.snapshot = lib.mkOption {
          type = lib.types.str;
          default = "blank";
          description = "zfs snapshot to rollback to";
        };
      };
      default = {};
    };
  };

  config = lib.mkIf cfg.enable (lib.mkMerge [
    {
      boot.kernelPackages = config.boot.zfs.package.latestCompatibleLinuxPackages;
      boot.initrd.systemd.enable = true;
    }
    (lib.mkIf cfg.remoteUnlock.enable {
      boot.initrd.systemd.network.enable = true;
      boot.initrd.systemd.contents."/root/.profile".text = "systemd-tty-ask-password-agent";
      boot.initrd.network = {
        enable = true;
        ssh = {
          enable = true;
          port = 2222;
          hostKeys = [ cfg.remoteUnlock.hostkey ];
          authorizedKeys = builtins.map (key:
            pkgs.mmell.lib.data.keys.ssh.${key}
          ) ["deploy" "home"];
        };
      };
    })
    (lib.mkIf cfg.impermanence.enable {
      # c/o https://discourse.nixos.org/t/impermanence-vs-systemd-initrd-w-tpm-unlocking/25167/2
      boot.initrd.systemd.services.rollback = {
        description = "Rollback ZFS datasets to a pristine state";
        wantedBy = [ "initrd.target" ];
        after = [ "zfs-import-zroot.service" ];
        before = [ "sysroot.mount" ];
        path = [ pkgs.zfs ];
        unitConfig.DefaultDependencies = "no";
        serviceConfig.Type = "oneshot";
        script = ''
          zfs rollback -r ${cfg.impermanence.dataset}@${cfg.impermanence.snapshot}
        '';
      };
    })
  ]);
}
