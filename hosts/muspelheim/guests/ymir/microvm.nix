{ config, ...}:
{
  microvm.shares = [{
    source = "/nix/store";
    mountPoint = "/nix/.ro-store";
    tag = "ro-store";
    proto = "virtiofs";
  } {
    source = "/persist/guests/ymir";
    mountPoint = "/persist";
    tag = "persist";
    proto = "virtiofs";
  }];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 1024;
  microvm.balloonMem = 1024;

  microvm.vcpu = 2;
  microvm.interfaces = [{
    type = "tap";
    id = "vm-20-ymir";
    mac = config.systemd.network.networks."20-tap".matchConfig.MACAddress;
  }];

  environment.persistence."/persist" = {
    directories = [
      "/var/lib/microvms"
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
