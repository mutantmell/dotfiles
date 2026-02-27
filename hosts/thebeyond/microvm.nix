{ config, pkgs, microvm, ... }:

{
  microvm = rec {
    vms = builtins.mapAttrs (name: type: if type != "directory" then abort "invalid guest: ${name}" else {
      inherit pkgs;
      config = pkgs.mmell.lib.builders.mk-microvm (import (./guests + "/${name}"));
    }) (builtins.readDir ./guests);
    autostart = builtins.attrNames vms;
  };

  # Persistence for microvm state
  environment.persistence."/persist".directories = [
    { directory = "/var/lib/microvms"; user = "microvm"; group = "kvm"; }
  ];

  # Ensure virtiofs share directories exist before microVMs start
  systemd.tmpfiles.rules = builtins.map (name:
    "d /persist/guests/${name}/static 0755 root root -"
  ) (builtins.attrNames (builtins.readDir ./guests));

  environment.systemPackages = [
    pkgs.mmell.mk-volume
  ];
}
