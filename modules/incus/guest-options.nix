{
  config,
  lib,
  ...
}: let
  cfg = config.incus-guest;
in {
  options.incus-guest = {
    type = lib.mkOption {
      type = lib.types.enum ["vm" "container"];
      default = "vm";
      description = "Whether this guest runs as an Incus VM or container.";
    };

    profile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Incus profile to apply to this instance.";
      example = "dev";
    };

    bridge = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Host bridge to attach this instance to via nictype=bridged.";
      example = "br20";
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to auto-start this instance on host boot.";
    };
  };

  config = lib.mkIf (cfg.type == "vm") {
    boot.initrd.availableKernelModules = ["virtiofs"];

    fileSystems."/boot".options = ["fmask=0077" "dmask=0077"];

    # The /static virtiofs mount is hotplugged by Incus after the incus-agent
    # starts (not available at boot). We declare it with nofail so NixOS doesn't
    # block boot waiting for it, and order it after the incus-agent.
    fileSystems."/static" = {
      device = "incus_static";
      fsType = "virtiofs";
      options = ["nofail" "x-systemd.after=incus-agent.service"];
    };

    # SSH host keys from host-side static directory (bind-mounted by incus)
    services.openssh.hostKeys = [
      {
        path = "/static/etc/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
    ];

    # Delay sshd until /static is mounted (host keys live there)
    systemd.services.sshd = {
      after = ["static.mount"];
      requires = ["static.mount"];
    };
  };
}
