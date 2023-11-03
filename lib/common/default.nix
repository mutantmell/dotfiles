{ lib, ... }:

{
  data = import ./data;
  network = rec {
    parsing = rec {
      ipv4 = lib.strings.splitString ".";
      cidr4 = cidr: let
        split-cidr = lib.strings.splitString "/" cidr;
        ipv4-string = builtins.head split-cidr;
        ipv4-parsed = ipv4 ipv4-string;
        mask-opt = builtins.tail split-cidr;
      in {
        ipv4.parsed = ipv4-parsed;
        ipv4.string = ipv4-string;
      } // (lib.attrsets.optionalAttrs (mask-opt != []) {
        mask = builtins.head mask-opt;
      });
    };
    formatting = {
      ipv4 = builtins.concatStringsSep ".";
    };
    replace-ipv4 = parts: ipv4: let
      parsed = parsing.ipv4 ipv4;
      num-parts = builtins.length parts;
      remaining = lib.lists.take (4 - num-parts) parsed;
    in
      if num-parts > 4
      then abort "replace-ipv4: invalid numbers of parts to replace (${num-parts})"
      else formatting.ipv4 (remaining ++ parts);
  };
  attrsets = {
    concatMapAttrsToList = f: v: lib.lists.flatten (lib.attrsets.mapAttrsToList f v);
  };
}
