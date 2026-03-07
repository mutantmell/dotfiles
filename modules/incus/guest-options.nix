{lib, ...}: {
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

    network = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Incus network to connect this instance to.";
      example = "incusbr20";
    };

    autoStart = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to auto-start this instance on host boot.";
    };
  };
}
