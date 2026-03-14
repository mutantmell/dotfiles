{
  # Ensure nftables is always enabled so that extraInputRules (nftables syntax)
  # are applied. Without this, hosts using iptables-nft silently ignore
  # nftables-syntax rules, leaving services unprotected.
  networking.nftables.enable = true;
}
