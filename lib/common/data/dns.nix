# One record model, rendered for router6/kresd and phantasma/Unbound.
{
  lib,
  net,
}: let
  localZones = ["internal.mutantmell.net" "internal"];
  localRecords =
    lib.listToAttrs (lib.concatMap (name: let
      host = net.hosts.${name};
      addresses = lib.optional (host ? ipv4) host.ipv4 ++ lib.optional (host ? ipv6) host.ipv6;
      names = ["${name}.internal.mutantmell.net" "${name}.internal"] ++ (net.hostAliases.${name} or []);
    in
      map (domain:
        lib.nameValuePair domain {
          inherit addresses;
          ttl = 3600;
          includeSubdomains = false;
        })
      names)
    net.dnsHosts)
    // {
      "pages.internal" = {
        addresses = [net.hosts.creil.ipv4 net.hosts.creil.ipv6];
        ttl = 3600;
        includeSubdomains = true;
      };
    };
in {
  inherit localZones localRecords;
  unbound = {
    local-zone =
      [''"mutantmell.net." transparent'']
      ++ map (name: ''"${name}." static'') localZones
      ++ lib.mapAttrsToList (name: _: ''"${name}." redirect'')
      (lib.filterAttrs (_: r: r.includeSubdomains) localRecords);
    local-data = lib.concatLists (lib.mapAttrsToList (name: record:
      map (address: let
        rrtype =
          if lib.hasInfix ":" address
          then "AAAA"
          else "A";
      in ''"${name}. ${toString record.ttl} IN ${rrtype} ${address}"'')
      record.addresses)
    localRecords);
  };
}
