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

    # IPv6 helpers
    isIPv6 = addr: lib.hasInfix ":" addr;
    isIPv4 = addr: !(isIPv6 addr) && lib.hasInfix "." addr;

    # Parse IPv6 CIDR notation (e.g., "fdc6:55f2:0a5e:a::1/64")
    parse-cidr6 = cidr: let
      split-cidr = lib.strings.splitString "/" cidr;
      ip = builtins.head split-cidr;
      mask-opt = builtins.tail split-cidr;
    in
      {
        inherit ip;
      }
      // lib.attrsets.optionalAttrs (mask-opt != []) {
        mask = lib.toInt (builtins.head mask-opt);
      };

    # Generate a /64 subnet from a /48 ULA prefix and VLAN tag
    # prefix: "fdc6:55f2:0a5e::/48", vlanId: 10 -> "fdc6:55f2:0a5e:a::/64"
    mkULASubnet = {
      prefix,
      vlanId,
    }: let
      # Remove ::/48 suffix to get base
      baseAddr = lib.strings.removeSuffix "::/48" prefix;
      # Convert VLAN ID to lowercase hex
      vlanHex = lib.toLower (lib.toHexString vlanId);
    in "${baseAddr}:${vlanHex}::/64";

    # Generate a host address in a ULA subnet
    # prefix: "fdc6:55f2:0a5e::/48", vlanId: 10, hostId: 1 -> "fdc6:55f2:0a5e:a::1/64"
    mkULAHostAddr = {
      prefix,
      vlanId,
      hostId ? 1,
    }: let
      baseAddr = lib.strings.removeSuffix "::/48" prefix;
      vlanHex = lib.toLower (lib.toHexString vlanId);
      hostHex = lib.toLower (lib.toHexString hostId);
    in "${baseAddr}:${vlanHex}::${hostHex}/64";

    # Get first IPv4 address from a list of addresses
    firstIPv4 = addrs: let
      v4 = lib.filter isIPv4 addrs;
    in
      if v4 == []
      then null
      else builtins.head v4;

    # Get first IPv6 address from a list of addresses
    firstIPv6 = addrs: let
      v6 = lib.filter isIPv6 addrs;
    in
      if v6 == []
      then null
      else builtins.head v6;
  in {
    parsing = {
      ipv4 = parse-ipv4;
      cidr4 = parse-cidr4;
      cidr6 = parse-cidr6;
    };
    formatting = {
      ipv4 = input: input.formatted;
    };
    replace-ipv4 = parts: ipv4: (parse-ipv4 ipv4).replace parts;
    # IPv6 exports
    inherit isIPv6 isIPv4 firstIPv4 firstIPv6 mkULASubnet mkULAHostAddr;
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
