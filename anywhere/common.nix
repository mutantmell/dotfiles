{ modulesPath, config, lib, pkgs, ... }:
let
  ssh-key = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIO22svFtlML/J11VMlNmqBkHdXH+BCWj1DXJkw+K7vbi malaguy@gmail.com";
in {
  boot.loader.grub = {
    efiSupport = true;
    efiInstallAsRemovable = true;
  };
  services.openssh.enable = true;

  environment.systemPackages = map lib.lowPrio [
    pkgs.curl
    pkgs.gitMinimal
  ];

  users.users.root.openssh.authorizedKeys.keys = [ ssh-key ];
  networking.hostId = lib.mkDefault "8425e349";
  system.stateVersion = "23.11";
  boot.initrd.network = {
    enable = true;
    ssh = {
      enable = true;
      port = 2222;
      hostKeys = [ cfg.remoteUnlock.hostkey ];
      authorizedKeys = [ ssh-key ];
    };
    postCommands = ''
      zpool import -a
      echo "zfs load-key -a; killall zfs" >> /root/.profile
    '';
  };
}
