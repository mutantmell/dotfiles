{
  config,
  lib,
  pkgs,
  ...
}: {
  microvm.hypervisor = "cloud-hypervisor";
  microvm.vsock.cid = 7;

  # microvm.nix hardcodes --posix-acl --xattr in the virtiofsd runner; both
  # return EOPNOTSUPP on NFS sources (the /media share), making the guest see
  # the directory as unreadable. Wrap virtiofsd to drop those two flags.
  microvm.virtiofsd.package = pkgs.writeShellScriptBin "virtiofsd" ''
    args=()
    for arg in "$@"; do
      case "$arg" in
        --posix-acl|--xattr) ;;
        *) args+=("$arg") ;;
      esac
    done
    exec ${lib.getExe pkgs.virtiofsd} "''${args[@]}"
  '';

  microvm.shares = [
    {
      source = "/nix/store";
      mountPoint = "/nix/.ro-store";
      tag = "ro-store";
      proto = "virtiofs";
    }
    {
      source = "/persist/guests/oracion/static";
      mountPoint = "/static";
      tag = "static";
      proto = "virtiofs";
    }
    {
      source = "/mnt/media";
      mountPoint = "/media";
      tag = "media";
      proto = "virtiofs";
    }
  ];
  fileSystems."/static".neededForBoot = lib.mkForce true;

  microvm.volumes = [
    {
      autoCreate = true;
      mountPoint = "/persist";
      image = "/persist/guests/oracion/images/persist.img";
      size = 10 * 1024;
    }
  ];
  fileSystems."/persist".neededForBoot = lib.mkForce true;

  microvm.mem = 8192;

  microvm.vcpu = 2;
  microvm.interfaces = [
    {
      type = "tap";
      id = "vm-100-oracion";
      mac = "5E:64:00:34:00:01";
    }
  ];
}
