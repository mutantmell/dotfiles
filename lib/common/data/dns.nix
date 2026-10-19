# Resolver-independent source of the homelab's Unbound local zones. Keep both
# gateway-side copies identical; only listeners and external forwarding differ.
{net}: {
  local-zone = [
    ''"mutantmell.net." transparent'' # local aliases, public DNS for other names
    ''"internal.mutantmell.net." static'' # unknown internal names never forward
    ''"internal." static''
    ''"pages.internal." redirect'' # apex + arbitrary user/repository names
  ];
  local-data =
    net.mkUnboundLocalData net.dnsHosts
    ++ net.mkUnboundAliasData net.dnsHosts
    ++ [
      ''"pages.internal. IN A ${net.hosts.creil.ipv4}"''
      ''"pages.internal. IN AAAA ${net.hosts.creil.ipv6}"''
    ];
}
