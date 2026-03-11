{lib, ...}: {
  data = import ./data {inherit lib;};
  network = let
    format-ipv4 = lib.concatStringsSep ".";
    parse-ipv4 = input: let
      ipv4-split = lib.strings.splitString "." input;
    in {
      # TODO: add validation
      parsed = ipv4-split;
      formatted = format-ipv4 ipv4-split;
      replace = parts: let
        num-parts = builtins.length parts;
        remaining = lib.lists.take (4 - num-parts) ipv4-split;
      in
        if num-parts > 4
        then abort "replace-ipv4: invalid numbers of parts to replace (${num-parts})"
        else format-ipv4 (remaining ++ parts);
    };
    parse-cidr4 = cidr: let
      split-cidr = lib.strings.splitString "/" cidr;
      mask-opt = builtins.tail split-cidr;
      ipv4-parsed = parse-ipv4 (builtins.head split-cidr);
    in
      {
        ipv4 = ipv4-parsed;
      }
      // lib.attrsets.optionalAttrs (mask-opt != []) {
        mask = builtins.head mask-opt;
        # TODO: add a new ipv4 section for ipv4 w/ mask applied
      };
  in {
    parsing = {
      ipv4 = parse-ipv4;
      cidr4 = parse-cidr4;
    };
  };
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
