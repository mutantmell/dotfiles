{ config, lib, pkgs, modulesPath, ... }:
{
  #imports = [ <nixpkgs/nixos/modules/profiles/qemu-guest.nix> ];
  imports =
    [ (modulesPath + "/profiles/qemu-guest.nix")
    ];

  boot.kernelModules = [];
  boot.loader.grub.device = "nodev";
  fileSystems."/" = { device = "/dev/vda1"; fsType = "ext4"; };

  networking = {
    defaultGateway = "165.227.0.1";
    defaultGateway6 = "2604:a880:2:d0::1";
    interfaces.ens3 = {
      ipv4.addresses = [ { address = "165.227.0.61"; prefixLength = 20; } ];
      ipv6.addresses = [
        { address = "2604:a880:2:d0::208b:d001"; prefixLength = 64; }
      ];
    };
    nameservers = [ "8.8.8.8" ];
  };
}
