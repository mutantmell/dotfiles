let
  mkConf = ip: { inherit ip; };
in {
  "jotunheimr" = mkConf "10.0.10.31";
  "yggdrasil" = mkConf "10.0.10.1";
}
