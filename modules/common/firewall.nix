{
  config,
  lib,
  ...
}: {
  options.common.firewall = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable the common firewall configuration (nftables).";
    };
  };

  config = lib.mkIf config.common.firewall.enable {
    # Ensure nftables is enabled so that extraInputRules (nftables syntax)
    # are applied. Without this, hosts using iptables-nft silently ignore
    # nftables-syntax rules, leaving services unprotected.
    networking.nftables.enable = true;
  };
}
