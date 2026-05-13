{
  config,
  lib,
  ...
}: let
  cfg = config.router6;
  r6lib = import ./lib.nix {inherit cfg lib;};

  inherit
    (lib)
    mkIf
    optionalString
    concatStringsSep
    flatten
    ;
  inherit (r6lib) flattenTopology dnsInterfaces getEffectiveAddresses partitionAF;
in {
  config = mkIf cfg.enable {
    services.kresd = {
      enable = true;
      listenPlain =
        [
          "127.0.0.1:53"
          "[::1]:53"
        ]
        ++ (flatten (map (
            iface: let
              ifaceData = lib.findFirst (i: i.name == iface) null flattenTopology;
              addrs =
                if ifaceData != null
                then getEffectiveAddresses ifaceData
                else [];
              split = partitionAF addrs;
            in
              (map (a: "${a.ip}:53") split.v4)
              ++ (map (a: "[${a.ip}]:53") split.v6)
          )
          dnsInterfaces));

      extraConfig = let
        upstreamServers = concatStringsSep ", " (map (s: "'${s}'") cfg.dns.upstream);
      in ''
        modules.load('policy')

        ${optionalString (cfg.dns.upstream != []) ''
          policy.add(policy.all(policy.FORWARD({${upstreamServers}})))
        ''}

        ${optionalString (!cfg.dns.enableDNSSEC) ''
          trust_anchors.set_insecure({ '.' })
        ''}

        cache.size = 100 * MB
      '';
    };
  };
}
