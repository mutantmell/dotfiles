{ config, pkgs, microvm, ... }:

{
  microvm.autostart = [
    "surtr2"
  ];

  microvms.vms = {
    surtr2 = rec {
      pkgs = import nixpkgs {};

      config = {
        # It is highly recommended to share the host's nix-store
        # with the VMs to prevent building huge images.
        microvm.shares = [{
          source = "/nix/store";
          mountPoint = "/nix/.ro-store";
          tag = "ro-store";
          proto = "virtiofs";
        }];
        microvm.mem = 1024;
        microvm.balloonMem = 1024;
        microvm.vcpu = 1;
        microvm.interfaces = [{
          type = "bridge";
          id = "br20";
        }];

        # Any other configuration for your MicroVM
        # [...]
        environment.systemPackages = [
          pkgs.home-manager
        ];
      };
    };
  };
}
