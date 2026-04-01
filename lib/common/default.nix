{lib, ...}: {
  data = import ./data {inherit lib;};
  nftables = {
    # Build an egress filter table body with default-drop output chain.
    # Allows established/related, loopback, and ICMP by default.
    # extraRules: list of nftables rule strings for host-specific allowlist.
    mkEgressFilter = extraRules: {
      family = "inet";
      content = ''
        chain output {
          type filter hook output priority 0; policy drop;

          ct state established,related accept
          oifname "lo" accept
          meta l4proto icmp accept
          meta l4proto icmpv6 accept

          ${lib.concatStringsSep "\n        " extraRules}
        }
      '';
    };
  };
  attrsets = {
    concatMapAttrsToList = f: v: lib.lists.flatten (lib.attrsets.mapAttrsToList f v);
  };
}
