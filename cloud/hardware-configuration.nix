{ config, lib, pkgs, nixpkgs, ... }:
{
  #imports = [ <nixpkgs/nixos/modules/profiles/qemu-guest.nix> ];
  imports = [ (builtins.toPath "${nixpkgs}/nixos/modules/profiles/qemu-guest.nix") ];
  
  boot.kernelModules = [];
  boot.loader.grub.device = "nodev";
  fileSystems."/" = { device = "/dev/vda1"; fsType = "ext4"; };

  networking = {
    defaultGateway = "165.227.0.1";
    defaultGateway6 = "2604:a880:2:d0::1";
    interfaces.ens3 = {
      ip4 = [ { address = "165.227.0.61"; prefixLength = 20; } ];
      ip6 = [
        { address = "2604:a880:2:d0::208b:d001"; prefixLength = 64; }
      ];
    };
    nameservers = [ "8.8.8.8" ];
  };
  users.extraUsers.root.openssh.authorizedKeys.keys = [
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com"
  ];
}
