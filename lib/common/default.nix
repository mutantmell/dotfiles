{ lib, ... }:

{
  data = import ./data;
  network = {
    parsing = let
      parse-ipv4 = lib.strings.splitString ".";
    in {
      ipv4 = parse-ipv4;
      cidr4 = cidr: let
        split-cidr = lib.strings.splitString "/" cidr;
        ipv4-parts = parse-ipv4 (builtins.head cidr);
        mask-opt = builtins.tail cidr;
      in {
        ipv4 = ipv4-parts;
      } // (lib.attrsets.optionalAttrs (mask-opt != []) {
        mask = builtins.head mask-opt;
      });
    };
    formatting = {
      ipv4 = builtins.concatStringsSep ".";
    };
    replace-ipv4 = parts: ipv4: let
      num-parts = builtins.length parts;
      remaining = lib.lists.take (4 - num-parts) ipv4;
    in
      if num-parts > 4
      then abort "replace-ipv4: invalid numbers of parts to replace (${num-parts})"
      else remaining ++ parts;
  };
}
