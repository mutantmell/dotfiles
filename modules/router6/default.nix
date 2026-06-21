{
  config,
  options,
  pkgs,
  lib,
  ...
}:
# Modern NixOS Router Module
# Uses: Kea (DHCP4/6), kresd (DNS), nftables (firewall), systemd-networkd (interfaces)
#
# Design principles:
# - Topology-driven configuration (define interfaces, derive everything else)
# - IPv6-first with full dual-stack support
# - Debuggable firewall rules with clear comments
# - Minimal magic, explicit configuration
let
  cfg = config.router6;

  inherit
    (lib)
    mkOption
    mkEnableOption
    types
    ;

  # nftables DSL library for structured rule generation
  nft = import ../../lib/nftables.nix {inherit lib;};

  # Shared network configuration submodule
  # Used by topology interfaces, VLANs, bridges, and bonds
  mkNetworkSubmodule = {
    allowedTypes ? ["disabled" "dhcp" "static" "pppoe"],
    defaultType ? "disabled",
  }:
    types.submodule ({config, ...}: {
      options = {
        type = mkOption {
          type = types.enum allowedTypes;
          default = defaultType;
          description = ''
            Network type:
            - disabled: Interface exists but has no IP configuration
            - dhcp: Get address via DHCP (typically WAN)
            - static: Static IP address(es)
            - pppoe: PPPoE connection (for DSL/fiber)
          '';
        };

        addresses = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "Static IPv4/IPv6 addresses in CIDR notation";
          example = ["10.97.10.1/24" "fd00:10::1/64"];
        };

        gateway = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = "Default gateway (for static WAN)";
        };

        dns = mkOption {
          type = types.listOf types.str;
          default = [];
          description = "DNS servers (for static WAN)";
        };

        dnsBlock = mkOption {
          type = types.bool;
          default = true;
          description = ''
            Whether clients on this network are subject to the
            `router6.dns.blocking` blocklist. `false` opts this subnet out —
            its queries reach the clean upstream answer with no blocking
            overlay (the per-interface bypass that replaces the old, leaky
            `sourceRoutes` mechanism). Only meaningful when
            `router6.dns.blocking.enable`; ignored otherwise.
          '';
        };

        zone = mkOption {
          type = types.nullOr (types.enum (builtins.attrNames cfg.zones));
          default = null;
          description = "Firewall zone for this network (must be a key in router6.zones)";
        };

        nat = mkOption {
          type = types.submodule {
            options.enable = mkEnableOption "NAT/masquerade on this interface";
          };
          default = {};
        };

        defaultRoute = mkOption {
          type = types.bool;
          default = false;
          description = "Use this interface for the default route";
        };

        dhcp = mkOption {
          description = "DHCP server configuration for this interface";
          type = types.submodule {
            options = {
              enable = mkEnableOption "DHCP server on this interface";

              poolStart = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "Start of DHCP pool (default: .100)";
              };

              poolEnd = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = "End of DHCP pool (default: .200)";
              };

              reservations = mkOption {
                type = types.listOf (types.submodule {
                  options = {
                    mac = mkOption {type = types.str;};
                    ip = mkOption {type = types.str;};
                    hostname = mkOption {
                      type = types.nullOr types.str;
                      default = null;
                    };
                  };
                });
                default = [];
                description = "Static DHCP reservations";
              };
            };
          };
          default = {};
        };

        dhcp6 = mkOption {
          description = "DHCPv6/SLAAC configuration";
          type = types.submodule {
            options = {
              enable = mkEnableOption "DHCPv6 server / RA on this interface";
              mode = mkOption {
                type = types.enum ["slaac" "stateful" "stateless"];
                default = "slaac";
                description = "IPv6 address assignment mode";
              };
              dnsAddress = mkOption {
                type = types.nullOr types.str;
                default = null;
                description = ''
                  IPv6 address to advertise as DNS server in Router Advertisements.
                  Should be the router's ULA address on this interface (stable,
                  always reachable, matches kresd listen address).
                  Must be set when dhcp6.enable is true.
                '';
                example = "fdc6:55f2:0a5e:a::1";
              };
            };
          };
          default = {};
        };

        mtu = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Override interface MTU";
        };

        required = mkOption {
          type = types.bool;
          default = config.type != "disabled";
          description = ''
            Whether this interface is required for boot.
            Defaults to false for disabled interfaces, true otherwise.
          '';
        };

        bridge = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Bridge to add this interface to. When set, the interface
            will be added to the specified bridge and will not have
            its own IP configuration (the bridge gets the IP config).
          '';
          example = "br0";
        };

        subnetId = mkOption {
          type = types.nullOr types.int;
          default = null;
          description = "Subnet ID for auto-generating IPv6 addresses from ULA prefix. For VLANs, defaults to VLAN tag.";
        };

        ipv6PrefixDelegation = mkOption {
          description = "Request IPv6 prefix delegation on this WAN interface";
          type = types.submodule {
            options = {
              enable = mkEnableOption "DHCPv6 Prefix Delegation client";
              prefixLength = mkOption {
                type = types.int;
                default = 48;
                description = "Prefix length to request from ISP (e.g. 48, 56, 60)";
              };
            };
          };
          default = {};
        };

        pdSubnetId = mkOption {
          type = types.nullOr types.str;
          default = null;
          description = ''
            Hex subnet ID for prefix delegation (e.g. "0xa" for VLAN 10).
            When set, this interface receives a /64 from the delegated prefix pool.
            The router gets <prefix>::1 on this subnet.
            Requires a WAN interface with ipv6PrefixDelegation.enable = true.
          '';
          example = "0xa";
        };
      };
    });

  # Type for nftables rules: either a raw string or a structured attribute set
  nftRuleType = lib.types.either lib.types.str lib.types.attrs;

  r6lib = import ./lib.nix {inherit cfg lib;};

  inherit
    (lib)
    mkIf
    optionals
    mapAttrsToList
    filterAttrs
    flatten
    filter
    elem
    ;
  inherit (builtins) attrNames attrValues hasAttr length;
  inherit (r6lib) flattenTopology devicesByKind;
in {
  imports = [
    ./dhcp.nix
    ./dns.nix
    ./dns-blocking.nix
    ./dns-isp-fallback.nix
    ./downstream-prefix-delegation.nix
    ./dyndns.nix
    ./firewall.nix
    ./networking.nix
  ];

  options.router6 = {
    enable = mkEnableOption "IPv6-ready router service";

    ulaPrefix = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = ''
        ULA /48 prefix for internal IPv6 addressing.
        When set, IPv6 addresses are automatically generated for VLANs
        based on their VLAN tag (e.g., VLAN 10 -> prefix:a::/64).
      '';
      example = "fdc6:55f2:0a5e::/48";
    };

    zones = mkOption {
      description = ''
        Firewall zone definitions. Each zone defines:
        - accessTo: which zones this zone can freely forward traffic to
        - forwardRules: per-destination-zone nftables rules (for filtered forwarding)
        - inputRules: nftables rules for traffic from this zone to the router itself
        - icmpEcho: whether the zone can ping the router

        Networks reference zones via their `zone` field (required on every network).
      '';
      default = {};
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          icmpEcho = mkOption {
            type = types.enum ["enable" "ipv4-only" "ipv6-only" "disable"];
            default = "disable";
            description = ''
              Whether interfaces in this zone can ping the router.
              - "enable": allow ICMPv4 + ICMPv6 echo-request/echo-reply
              - "ipv4-only": allow only ICMPv4 echo
              - "ipv6-only": allow only ICMPv6 echo
              - "disable": no ICMP echo (PMTUD and NDP are always allowed by baseRules)
            '';
          };

          accessTo = mkOption {
            type = types.listOf (types.enum (builtins.attrNames cfg.zones));
            default = [];
            description = ''
              Zones this zone can freely forward traffic to (blanket accept).
              Values are restricted to defined zone names (validated by type).
            '';
          };

          forwardRules = mkOption {
            type = types.attrsOf (types.listOf nftRuleType);
            default = {};
            description = ''
              Per-destination-zone forwarding rules. Keys are target zone names,
              values are lists of nftables rules (same DSL as extraForwardRules).
              Rules must NOT specify iifname or oifname (auto-set from zones).
              A destination zone must NOT also appear in accessTo.
            '';
          };

          inputRules = mkOption {
            type = types.listOf nftRuleType;
            default = [];
            description = ''
              Rules for traffic from this zone's interfaces to the router itself.
              Same DSL as extraInputRules but must NOT specify iifname (auto-set).
            '';
          };
        };
      }));
    };

    routes = mkOption {
      description = ''
        Static routes added to systemd-networkd on the named interface.
        Use for cross-gateway reachability where no protocol carries the
        route automatically (e.g. point-to-point transit links between
        gateways with downstream subnets behind each).

        Each entry is grouped by `interface` and emitted into that
        interface's network file's [Route] section.
      '';
      default = [];
      type = types.listOf (types.submodule {
        options = {
          destination = mkOption {
            type = types.str;
            description = "Destination prefix in CIDR notation (IPv4 or IPv6).";
            example = "10.97.0.0/16";
          };
          gateway = mkOption {
            type = types.str;
            description = "Next-hop address. AF must match destination.";
            example = "10.255.255.2";
          };
          interface = mkOption {
            type = types.str;
            description = ''
              Interface to install the route on. Must reference a
              topology device or VLAN that owns the network file
              this route is rendered into.
            '';
            example = "brTRANSIT";
          };
          metric = mkOption {
            type = types.nullOr types.int;
            default = null;
            description = "Optional route metric.";
          };
        };
      });
    };

    downstreamPrefixDelegations = mkOption {
      description = ''
        DHCPv6 Prefix Delegation servers for downstream routers.

        Each entry derives the active upstream delegated prefix from a
        systemd-networkd WAN interface, serves a child prefix to a downstream
        router with Kea DHCPv6-PD, and installs a route for the delegated
        prefix through the downstream client.
      '';
      default = {};
      type = types.attrsOf (types.submodule ({name, ...}: {
        options = {
          sourceInterface = mkOption {
            type = types.str;
            description = "Upstream systemd-networkd interface that receives the parent DHCPv6-PD prefix.";
            example = "enp4s0";
          };

          interface = mkOption {
            type = types.str;
            description = "Downstream interface where Kea should serve DHCPv6-PD.";
            example = "brTRANSIT";
          };

          linkSubnet6 = mkOption {
            type = types.str;
            description = "IPv6 subnet on the downstream link where DHCPv6-PD requests arrive.";
            example = "fdc6:55f2:0a5e:ffff::/64";
          };

          delegatedLength = mkOption {
            type = types.ints.between 1 128;
            default = 57;
            description = "Prefix length to delegate to the downstream router.";
          };

          childIndex = mkOption {
            type = types.ints.unsigned;
            default = 0;
            description = ''
              Zero-based child prefix index selected after splitting the parent
              prefix to delegatedLength. For example, childIndex = 1 selects
              the upper /57 from a /56.
            '';
          };

          refreshInterval = mkOption {
            type = types.str;
            default = "5min";
            description = "How often to refresh the generated Kea config for ISP prefix changes.";
          };
        };
      }));
    };

    topology = mkOption {
      description = "Network topology definition";
      default = {};
      type = types.attrsOf (types.submodule ({
        name,
        config,
        ...
      }: {
        options = {
          kind = mkOption {
            type = types.enum ["physical" "bond" "bridge" "batman" "wireguard"];
            default =
              if config.mac != null || config.hardwareName != null
              then "physical"
              else
                throw ''
                  Device '${name}' must specify 'kind'.

                  Valid kinds: "bond", "bridge", "batman", "wireguard"
                  (Physical interfaces with mac/hardwareName auto-default to "physical")
                '';
            description = ''
              Device type.

              - "physical": Network interface card (auto-detected if mac/hardwareName present)
              - "bond": Link aggregation device (requires mode and members)
              - "bridge": Layer 2 bridge (requires members)
              - "batman": Batman-adv mesh device (requires batman config)
              - "wireguard": WireGuard VPN tunnel (requires wireguard config)
            '';
          };

          mac = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "MAC address to match for interface renaming";
            example = "00:11:22:33:44:55";
          };

          hardwareName = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Original hardware interface name";
            example = "enp0s3";
          };

          members = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "For bonds: physical interface names. For bridges: VLAN/interface names. For batman: physical interface or bond names.";
          };

          mode = mkOption {
            type = types.nullOr (types.enum [
              "balance-rr"
              "active-backup"
              "balance-xor"
              "broadcast"
              "802.3ad"
              "balance-tlb"
              "balance-alb"
            ]);
            default = null;
            description = "Bonding mode (required for bond devices)";
          };

          lacpTransmitRate = mkOption {
            type = types.nullOr (types.enum ["slow" "fast"]);
            default = null;
            description = "LACP transmit rate (only for 802.3ad mode)";
          };

          miiMonitorSec = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "MII link monitoring interval";
          };

          network = mkOption {
            type = mkNetworkSubmodule {};
            default = {type = "disabled";};
          };

          vlans = mkOption {
            type = types.attrsOf (types.submodule {
              options = {
                tag = mkOption {
                  type = types.ints.between 1 4094;
                  description = "VLAN ID (1-4094)";
                };
                network = mkOption {
                  type = mkNetworkSubmodule {
                    allowedTypes = ["disabled" "static"];
                    defaultType = "static";
                  };
                };
              };
            });
            default = {};
          };

          batman = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                gatewayMode = mkOption {
                  type = types.enum ["off" "client" "server"];
                  default = "off";
                };
                routingAlgorithm = mkOption {
                  type = types.enum ["batman-iv" "batman-v"];
                  default = "batman-v";
                };
              };
            });
            default = null;
            description = "Batman-adv mesh configuration (makes this a batadv interface)";
          };

          wireguard = mkOption {
            type = types.nullOr (types.submodule {
              options = {
                privateKeyFile = mkOption {
                  type = types.path;
                  description = "Path to wireguard private key file";
                };
                port = mkOption {
                  type = types.nullOr types.port;
                  default = null;
                  description = "Listen port (required if accepting connections)";
                };
                peers = mkOption {
                  type = types.listOf (types.submodule {
                    options = {
                      publicKey = mkOption {type = types.str;};
                      allowedIPs = mkOption {type = types.listOf types.str;};
                      endpoint = mkOption {
                        type = types.nullOr types.str;
                        default = null;
                      };
                      persistentKeepalive = mkOption {
                        type = types.nullOr types.int;
                        default = null;
                      };
                    };
                  });
                  default = [];
                };
                openFirewall = mkOption {
                  type = types.bool;
                  default = false;
                  description = "Open firewall for wireguard port";
                };
              };
            });
            default = null;
          };
        };
      }));
    };

    dns = mkOption {
      type = types.submodule {
        options = {
          upstream = mkOption {
            type = types.listOf types.str;
            default = [];
            description = "Upstream DNS servers";
          };

          upstreamPolicy = mkOption {
            type = types.enum ["forward" "stub"];
            default = "forward";
            description = ''
              kresd policy applied to the primary upstream.

              - `forward` — kresd locally re-validates DNSSEC. The upstream
                must return the full DNSSEC chain (RRSIGs, DS, DNSKEY).
                Use when the upstream is not trusted to validate.
              - `stub`    — kresd does NOT re-validate. The upstream's AD
                bit is not enforced; kresd just proxies. Use only when
                the upstream is itself an authoritative validator AND the
                network path between kresd and the upstream is trusted —
                this is "skip redundant work", not a security boundary.
            '';
          };

          fallbackPolicy = mkOption {
            type = types.enum ["forward" "stub"];
            default = "forward";
            description = ''
              kresd policy applied to the fallback upstream. Same
              semantics as `upstreamPolicy`. Defaults to `forward`
              because fallback resolvers (ISP-supplied, public DNS) are
              typically untrusted and DNSSEC re-validation is the safer
              default.
            '';
          };

          localDomain = mkOption {
            type = types.nullOr types.str;
            default = "local";
            description = "Local domain for DHCP hostnames";
          };

          enableDNSSEC = mkOption {
            type = types.bool;
            default = true;
            description = "Enable DNSSEC validation";
          };

          blocking = mkOption {
            description = ''
              Optional Blocky ad-blocking resolver placed *in front* of kresd.
              When enabled, Blocky binds the client-facing `:53` on the zone
              gateways and kresd retreats to a loopback backend; when disabled,
              kresd serves `:53` directly and Blocky is not started. Either
              way the router serves DNS on `:53` — this only changes which
              service is exposed directly.

              Blocky sees real client source IPs and applies a per-client
              blocklist overlay before its own cache, then forwards clean
              queries to kresd. This is the leak-free replacement for the
              removed `sourceRoutes` bypass: blocking is a per-request answer
              policy keyed on client identity, never a choice of which cached
              upstream to consult.

              Per-interface opt-out lives on the topology interface via
              `network.dnsBlock = false`.
            '';
            type = types.submodule {
              options = {
                enable = mkEnableOption "Blocky ad-blocking in front of the resolver";

                denylists = mkOption {
                  type = types.attrsOf (types.listOf types.path);
                  default = {};
                  example = lib.literalExpression ''
                    { ads = [ "''${pkgs.mmell.stevenblack-hosts}/hosts" ]; }
                  '';
                  description = ''
                    Group name → list of denylist sources, keyed by group.
                    Sources MUST be local store paths, never `https://` URLs:
                    a URL would make Blocky resolve the list host through
                    itself before it is ready (bootstrap chicken-and-egg), and
                    pins the list to the flake for reproducibility.
                  '';
                };

                defaultGroups = mkOption {
                  type = types.listOf types.str;
                  default = ["ads"];
                  description = ''
                    Blocking groups applied to clients that are not opted out
                    (i.e. on interfaces with `network.dnsBlock = true`).
                  '';
                };

                conditionalDomains = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  example = ["internal" "internal.mutantmell.net" "mutantmell.net"];
                  description = ''
                    Domains Blocky must forward to the backend rather than
                    short-circuit to NXDOMAIN. Blocky NXDOMAINs RFC 6761 /
                    ICANN special-use suffixes (including `.internal`) unless
                    they have a conditional upstream — without this the
                    homelab's split-horizon `*.internal` naming breaks.
                  '';
                };
              };
            };
            default = {};
          };

          fallbackFromLease = mkOption {
            type = types.nullOr types.str;
            default = null;
            example = "enp4s0";
            description = ''
              WAN interface whose DHCP lease supplies fallback DNS servers.
              When set, the lease's DNS= field is rendered into a kresd-loaded
              Lua file. Static fallbackUpstream is used when the lease is
              missing or has no DNS entries.
            '';
          };

          fallbackUpstream = mkOption {
            type = types.listOf types.str;
            default = ["9.9.9.9" "149.112.112.112"];
            description = "Static fallback resolvers when fallbackFromLease is null or unavailable.";
          };

          interception = mkOption {
            type = types.submodule {
              options = {
                enable = mkEnableOption "DNS interception (DNAT non-router DNS to kresd)";

                excludeAddresses = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = ''
                    IPs excluded from interception (both source and destination).
                    When empty, defaults to dns.upstream addresses.
                  '';
                };

                extraExcludeAddresses = mkOption {
                  type = types.listOf types.str;
                  default = [];
                  description = "Additional excluded IPs (appended to excludeAddresses).";
                };

                target = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "IPv4 DNAT target. Defaults to first IPv4 of a DNS-serving interface.";
                };

                target6 = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "IPv6 DNAT target. Defaults to first IPv6/ULA of a DNS-serving interface.";
                };
              };
            };
            default = {};
          };
        };
      };
      default = {};
    };

    dyndns = mkOption {
      type = types.submodule {
        options = {
          enable = mkEnableOption "dynamic DNS updates";

          protocol = mkOption {
            type = types.enum ["namecheap"];
            default = "namecheap";
            description = "Dynamic DNS update protocol";
          };

          server = mkOption {
            type = types.str;
            default = "";
            description = "Server URL for dynamic DNS updates";
          };

          interface = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Interface to get the external IP address from.
              If null, infers from the first DHCP interface in the topology.
            '';
          };

          hosts = mkOption {
            type = types.listOf types.str;
            default = [];
            description = ''
              DNS hostnames to update. Use "@" for the bare domain.
              Mutually exclusive with hostsFile. Baked into the nix store —
              use hostsFile if the hostnames are sensitive.
            '';
            example = ["@" "www"];
          };

          hostsFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Path to a file containing whitespace-separated DNS hostnames to
              update (read at runtime, so the names stay out of the nix store).
              Use "@" for the bare domain. Mutually exclusive with hosts.
            '';
          };

          renewPeriod = mkOption {
            type = types.str;
            default = "60m";
            description = "How often to check and update the dynamic DNS IP address";
          };

          domain = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Domain name (plaintext). Mutually exclusive with domainFile.";
          };

          domainFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Path to file containing the domain name. Mutually exclusive with domain.";
          };

          passwordFile = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Path to file containing the dynamic DNS password";
          };
        };
      };
      default = {};
      description = "Dynamic DNS update configuration";
    };

    firewall = mkOption {
      type = types.submodule {
        options = {
          baseRules = mkOption {
            type = types.bool;
            default = true;
            description = ''
              Include base firewall rules that zones build on top of:
              - Connection tracking (ct state established,related accept)
              - Loopback accept
              - Essential ICMP/ICMPv6 (PMTUD, Neighbor Discovery)
              - TCP MSS clamping in forward chain
              When false, only zone-defined rules and extra*Rules are generated.
            '';
          };

          icmpRateLimit = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = ''
              Rate limit for ICMP echo accept rules in zone input chains.
              When set, injects `limit rate <value>` into the auto-generated
              ICMP echo-request/echo-reply accept rules.
              Example: "30/second burst 60 packets"
            '';
          };

          logDropped = mkOption {
            type = types.bool;
            default = false;
            description = ''
              Log dropped packets in input and forward chains.
              Adds rate-limited log rules before the implicit policy drop.
            '';
          };

          logDroppedRateLimit = mkOption {
            type = types.str;
            default = "5/minute";
            description = "Rate limit for drop logging rules.";
          };

          egressPolicy = mkOption {
            type = types.enum ["accept" "drop" "log"];
            default = "accept";
            description = ''
              Output chain policy for router-originated traffic.
              This is the router6 equivalent of lib.nftables.mkEgressFilter,
              which serves standalone microVM/container guests instead.
              - "accept": empty chain with policy accept (default, backwards compatible)
              - "drop": policy drop with base rules + egressRules
              - "log": policy accept with base rules + egressRules + rate-limited log for unmatched
            '';
          };

          egressRules = mkOption {
            type = types.listOf nftRuleType;
            default = [];
            description = "Rules for the output chain (when egressPolicy is drop or log).";
          };

          egressLogPrefix = mkOption {
            type = types.str;
            default = "EGRESS-UNMATCHED: ";
            description = "Log prefix for unmatched egress traffic (log mode only).";
          };

          extraInputRules = mkOption {
            type = types.listOf nftRuleType;
            default = [];
            description = ''
              Extra nftables rules for input chain.
              Each rule can be either a raw string or a structured attribute set.
              Example:
                [
                  { iifname = "eth0"; tcp.dport = 22; verdict = "accept"; }
                  "udp dport 5000 accept"  # raw string escape hatch
                ]
            '';
          };

          extraForwardRules = mkOption {
            type = types.listOf nftRuleType;
            default = [];
            description = ''
              Extra nftables rules for forward chain.
              Each rule can be either a raw string or a structured attribute set.
            '';
          };

          extraNatRules = mkOption {
            type = types.listOf nftRuleType;
            default = [];
            description = ''
              Extra nftables rules for NAT prerouting chain (DNAT, redirect).
              Each rule can be either a raw string or a structured attribute set.
            '';
          };

          extraNatPostroutingRules = mkOption {
            type = types.listOf nftRuleType;
            default = [];
            description = ''
              Extra nftables rules for NAT postrouting chain (SNAT, masquerade).
              Each rule can be either a raw string or a structured attribute set.
            '';
          };

          extraNat6Rules = mkOption {
            type = types.listOf nftRuleType;
            default = [];
            description = ''
              Extra nftables rules for IPv6 NAT prerouting chain (DNAT, redirect).
              Each rule can be either a raw string or a structured attribute set.
            '';
          };

          extraNat6PostroutingRules = mkOption {
            type = types.listOf nftRuleType;
            default = [];
            description = ''
              Extra nftables rules for IPv6 NAT postrouting chain (SNAT, masquerade).
              Each rule can be either a raw string or a structured attribute set.
            '';
          };

          portForwards = mkOption {
            type = types.listOf (types.submodule {
              options = {
                proto = mkOption {
                  type = types.enum ["tcp" "udp" "both"];
                  default = "tcp";
                };
                sourcePort = mkOption {type = types.port;};
                destination = mkOption {
                  type = types.str;
                  description = "ip:port to forward to";
                };
                sourceInterface = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Limit to specific interface (default: all external)";
                };
                destinationInterface = mkOption {
                  type = types.nullOr types.str;
                  default = null;
                  description = "Restrict forward-accept rule to specific outbound interface";
                };
              };
            });
            default = [];
            description = "Port forwarding rules (DNAT)";
          };
        };
      };
      default = {};
    };
  };

  config = mkIf cfg.enable {
    assertions =
      # DHCPv6 server on WAN interface assertion
      [
        {
          assertion =
            !(lib.any (
                i:
                  (i.network.dhcp6.enable or false) && i.network.type == "dhcp"
              )
              flattenTopology);
          message = "router6: dhcp6.enable (RA server) cannot be set on a DHCP client interface — it would send RAs upstream to the ISP";
        }
      ]
      # dhcp6.dnsAddress must be set when dhcp6.enable is true
      ++ (map (i: {
        assertion = (i.network.dhcp6.dnsAddress or null) != null;
        message = "router6: interface '${i.name}' has dhcp6.enable = true but no dhcp6.dnsAddress set. Set it to the router's ULA address on this interface (e.g. the address kresd listens on).";
      }) (filter (i: i.network.dhcp6.enable or false) flattenTopology))
      # pdSubnetId requires at least one PD source
      ++ (let
        hasPdSource = lib.any (i: i.network.ipv6PrefixDelegation.enable or false) flattenTopology;
        pdReceivers = filter (i: (i.network.pdSubnetId or null) != null) flattenTopology;
      in
        optionals (pdReceivers != []) [
          {
            assertion = hasPdSource;
            message = "router6: interface(s) ${lib.concatMapStringsSep ", " (i: "'${i.name}'") pdReceivers} have pdSubnetId set but no interface has ipv6PrefixDelegation.enable = true";
          }
        ])
      # DNSSEC: pinned static root KSK must be available in nixpkgs.
      # This is a static existence check (dns-root-data ships in nixpkgs),
      # not a runtime defense — its purpose is to make the dependency
      # explicit so a stripped pkgs set fails eval, not boot.
      ++ (optionals cfg.dns.enableDNSSEC [
        {
          assertion = pkgs ? dns-root-data;
          message = "router6.dns.enableDNSSEC = true requires pkgs.dns-root-data (provides the IANA root KSK at \${pkgs.dns-root-data}/root.key).";
        }
      ])
      # Dynamic DNS assertions
      ++ (optionals cfg.dyndns.enable [
        {
          assertion = cfg.dyndns.passwordFile != null;
          message = "router6.dyndns: passwordFile must be set when dyndns is enabled";
        }
        {
          assertion = cfg.dyndns.domain != null || cfg.dyndns.domainFile != null;
          message = "router6.dyndns: either domain or domainFile must be set";
        }
        {
          assertion = !(cfg.dyndns.domain != null && cfg.dyndns.domainFile != null);
          message = "router6.dyndns: domain and domainFile are mutually exclusive";
        }
        {
          assertion = cfg.dyndns.hosts != [] || cfg.dyndns.hostsFile != null;
          message = "router6.dyndns: either hosts or hostsFile must be set";
        }
        {
          assertion = !(cfg.dyndns.hosts != [] && cfg.dyndns.hostsFile != null);
          message = "router6.dyndns: hosts and hostsFile are mutually exclusive";
        }
        {
          assertion = cfg.dyndns.server != "";
          message = "router6.dyndns: server must be set";
        }
      ])
      # Zone assertions: accessTo and forwardRules must not overlap
      ++ lib.concatMap (
        zoneName: let
          zone = cfg.zones.${zoneName};
        in
          map (dstZone: {
            assertion = !elem dstZone zone.accessTo;
            message = "Zone '${zoneName}': destination '${dstZone}' appears in both accessTo and forwardRules. Use one or the other.";
          }) (attrNames zone.forwardRules)
      ) (attrNames cfg.zones)
      # forwardRules keys reference valid zones
      ++ lib.concatMap (
        zoneName: let
          zone = cfg.zones.${zoneName};
        in
          map (target: {
            assertion = hasAttr target cfg.zones;
            message = "Zone '${zoneName}': forwardRules references unknown zone '${target}'";
          }) (attrNames zone.forwardRules)
      ) (attrNames cfg.zones)
      # inputRules must not contain iifname (it's auto-set)
      ++ lib.concatMap (
        zoneName: let
          zone = cfg.zones.${zoneName};
        in
          lib.imap0 (i: rule: {
            assertion = !(lib.isAttrs rule && hasAttr "iifname" rule);
            message = "Zone '${zoneName}': inputRules[${toString i}] must not specify iifname (auto-set from zone interfaces)";
          })
          zone.inputRules
      ) (attrNames cfg.zones)
      # forwardRules must not contain iifname or oifname
      ++ lib.concatMap (
        zoneName: let
          zone = cfg.zones.${zoneName};
        in
          lib.concatMap (
            dstZone:
              lib.imap0 (i: rule: {
                assertion = !(lib.isAttrs rule && (hasAttr "iifname" rule || hasAttr "oifname" rule));
                message = "Zone '${zoneName}': forwardRules.${dstZone}[${toString i}] must not specify iifname/oifname (auto-set from zone interfaces)";
              })
              zone.forwardRules.${dstZone}
          ) (attrNames zone.forwardRules)
      ) (attrNames cfg.zones)
      # router6.routes: interface must exist as a topology device or VLAN
      ++ (let
        allVlanNames = lib.concatMap (d: attrNames (d.vlans or {})) (attrValues cfg.topology);
        knownIfaces = (attrNames cfg.topology) ++ allVlanNames;
      in
        lib.imap0 (i: route: {
          assertion = elem route.interface knownIfaces;
          message = "router6.routes[${toString i}]: interface '${route.interface}' is not a topology device or VLAN";
        })
        cfg.routes)
      # Wireguard openFirewall requires port
      ++ (mapAttrsToList (name: iface: {
        assertion = !(iface.wireguard.openFirewall or false) || (iface.wireguard.port or null) != null;
        message = "Wireguard interface ${name}: openFirewall requires port to be set";
      }) (filterAttrs (n: v: v.wireguard != null) cfg.topology))
      # Bond member validation
      ++ flatten (mapAttrsToList (
        bondName: bond:
          map (member: {
            assertion =
              hasAttr member cfg.topology
              && cfg.topology.${member}.kind == "physical";
            message = "Bond '${bondName}' member '${member}' must exist and be a physical interface";
          }) (bond.members or [])
      ) (devicesByKind "bond"))
      # Batman member validation
      ++ flatten (mapAttrsToList (
        batmanName: batman:
          map (member: {
            assertion =
              hasAttr member cfg.topology
              && elem cfg.topology.${member}.kind ["physical" "bond"];
            message = "Batman '${batmanName}' member '${member}' must exist and be a physical interface or bond";
          }) (batman.members or [])
      ) (devicesByKind "batman"))
      # Bridge member validation (members can be VLANs)
      ++ flatten (mapAttrsToList (
        bridgeName: bridge:
          map (member: {
            assertion =
              hasAttr member cfg.topology
              || lib.any (dev: hasAttr member (dev.vlans or {})) (attrValues cfg.topology);
            message = "Bridge '${bridgeName}' references non-existent member '${member}'";
          }) (bridge.members or [])
      ) (devicesByKind "bridge"))
      # Bonds must have members; bridges must have members OR VLANs
      ++ mapAttrsToList (name: device: {
        assertion =
          if device.kind == "bond"
          then length (device.members or []) > 0
          else if device.kind == "bridge"
          then length (device.members or []) > 0 || length (attrNames (device.vlans or {})) > 0
          else true;
        message =
          if device.kind == "bond"
          then "Bond '${name}' has no members defined"
          else "Bridge '${name}' has no members and no VLANs defined";
      })
      cfg.topology
      # Bonds must have mode
      ++ mapAttrsToList (name: device: {
        assertion = device.mode != null;
        message = "Bond '${name}' must have mode defined";
      }) (devicesByKind "bond")
      # Cross-kind membership: an interface cannot be both a batman member and a bridge member
      ++ (let
        batmanMembers = lib.concatMap (bat: bat.members or []) (attrValues (devicesByKind "batman"));
        bridgeMembers = lib.concatMap (br: br.members or []) (attrValues (devicesByKind "bridge"));
        overlap = filter (m: elem m bridgeMembers) batmanMembers;
      in
        map (member: {
          assertion = false;
          message = "Interface '${member}' is a member of both a batman device and a bridge. Linux only supports one master per interface. Remove it from the bridge — batman forwards traffic through to its soft interface automatically.";
        })
        overlap)
      # ---- Security assertions ----
      # Derive the set of WAN zone names: zones assigned to NAT-enabled interfaces.
      ++ (let
        wanZones = lib.unique (
          lib.concatMap (i:
            lib.optional
            ((i.network.zone or null) != null && (i.network.nat.enable or false))
            i.network.zone)
          flattenTopology
        );
        # All WireGuard listen ports declared in the topology
        wgPorts = lib.concatMap (name: let
          port = cfg.topology.${name}.wireguard.port or null;
        in
          lib.optional (port != null) port)
        (attrNames (filterAttrs (_: v: v.wireguard != null) cfg.topology));
        # A rule is "WireGuard-shaped" if it accepts UDP on a WireGuard port only
        isWgAccept = rule:
          lib.isAttrs rule
          && (rule.verdict or null) == "accept"
          && (rule ? udp)
          && !(rule ? tcp)
          && (let
            dp = rule.udp.dport or null;
          in
            dp
            != null
            && (
              if lib.isList dp
              then lib.all (p: elem p wgPorts) dp
              else elem dp wgPorts
            ));
      in
        # (a) WAN zone inputRules must only accept WireGuard ports
        lib.concatMap (zoneName: let
          zone = cfg.zones.${zoneName};
        in
          lib.imap0 (i: rule: {
            assertion = isWgAccept rule;
            message = "router6: WAN zone '${zoneName}': inputRules[${toString i}] must only accept WireGuard ports. Found a non-WG rule. Use zone.extraInputRules for other intentional exceptions.";
          })
          zone.inputRules)
        wanZones
        # (b) No DHCP server on NAT (WAN) interfaces
        ++ lib.concatMap (i: [
          {
            assertion = !(i.network.dhcp.enable or false);
            message = "router6: interface '${i.name}' has nat.enable = true and dhcp.enable = true. A DHCP server on a WAN interface would advertise to the ISP segment.";
          }
        ]) (filter (i: i.network.nat.enable or false) flattenTopology)
        # (c) icmpEcho = "disable" on NAT zones
        ++ map (zoneName: {
          assertion = (cfg.zones.${zoneName}.icmpEcho or "disable") == "disable";
          message = "router6: WAN zone '${zoneName}' has icmpEcho != 'disable'. NAT zones should not respond to ICMP echo from the public internet.";
        })
        wanZones);
  };
}
