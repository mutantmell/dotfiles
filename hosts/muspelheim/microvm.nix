{ config, pkgs, microvm, ... }:

{
  microvm = rec {
    vms = builtins.mapAttrs (name: type: if type != "directory" then abort "invalid guest: ${name}" else {
      inherit pkgs;
      config = pkgs.mmell.lib.builders.mk-microvm (import (./guests + "/${name}"));
    }) (builtins.readDir ./guests);
    autostart = builtins.attrNames vms;
  };

  environment.persistence."/persist" = {
    directories = [
      { directory = "/var/lib/microvms"; user = "microvm"; group = "kvm"; }
    ];
  };

  environment.systemPackages = [
    pkgs.mmell.mk-volume
    (pkgs.writeShellApplication {
      name = "mk-volume-with-ssh-key";
      runtimeInputs = [ pkgs.mmell.mk-volume ];
      text = ''
        set -euxo pipefail
        if [ "$#" -lt 2 ]; then
          echo "invalid number of args"
          exit 1
        fi;

        NAME="$1"
        SIZE="$2"

        OUTDIR=./"$NAME".volume
        echo "$OUTDIR"
        if [ -d "$OUTDIR" ]; then
          echo "directory already exists"
          exit 2
        fi
        mkdir "$OUTDIR"
        cd "$OUTDIR"

        ssh-keygen -t ed25519 -f ssh_host_ed25519_key -q -N ""
        mkdir -p ./volume/static/ssh
        cp ssh_host_ed25519_key* ./volume/static/ssh/

        ${pkgs.mmell.mk-volume}/bin/mk-volume "$NAME" "$SIZE" "ext4" ./volume
      '';
    })
  ];
}
