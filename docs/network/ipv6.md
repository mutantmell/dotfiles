# IPv6 addressing and delegated prefixes

Stable internal ingress uses registry-derived ULA addresses. SLAAC privacy addresses serve outbound traffic where Router Advertisements are accepted. router6 supports WAN DHCPv6 prefix delegation, per-interface RA policy, and Kea DHCPv6 modes; read current host configuration to determine enabled behavior.

Stable GUA token addressing and a matching ULA offset are a proposed migration, not the current registry format. A stable token follows delegated prefixes but does not authorize inbound traffic or remove the need for firewall policy. A sparse suffix is an addressing convention, not a security boundary.

Changing ULA suffixes affects DNS, static host addresses, ACLs, tunnels, and consumers on both gateways. Stage compatibility, test source-address selection and renumbering, and provide rollback before adopting the proposed `::a0XX` convention. DHCPv6 reservations alone cannot derive an address from an arbitrary future delegated prefix.

The dated BT8 reference also records unfinished per-slot dev-machine IPv6 identity work. Defer it to the [stable-ingress rollout](https://forgejo.internal/mutantmell-net/dotfiles/issues/240) when IPv6 slot reachability is required; select token/reservation behavior against the actual guest/RA design rather than treating old DHCPv6 wording as a decision. Existing IPv4 slot acceptance does not prove IPv6 routing or isolation.
