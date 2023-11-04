{ config, pkgs, microvm, ... }:

{
  microvm.autostart = [
    "surtr2"
  ];

  microvm.vms = {
    surtr2 = {
      inherit pkgs;

      config = pkgs.mmell.lib.builders.mk-microvm {
        # It is highly recommended to share the host's nix-store
        # with the VMs to prevent building huge images.
        microvm.shares = [{
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }];
        microvm.writableStoreOverlay = "/nix/.rw-store";
        microvm.mem = 1024;
        microvm.balloonMem = 1024;
        microvm.vcpu = 1;
        microvm.interfaces = [{
          type = "bridge";
          bridge = "br100";
          id = "ens3";
          mac = "5E:41:3F:F4:AB:B4";
        }];

        # Any other configuration for your MicroVM
        # [...]
        environment.systemPackages = [
          pkgs.home-manager
        ];
        common.openssh.enable = true;
        common.networking = {
          enable = true;
          hostname = "surtr2"; # TODO: find way to default here?
          interface = "ens3";
        };
      };
    };
  };
}
