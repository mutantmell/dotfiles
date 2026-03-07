# Unit tests for nftables DSL library
#
# Run: nix-instantiate --eval --strict tests/lib/nftables.nix
# Or:  nix eval -f tests/lib/nftables.nix
#
# Returns true if all tests pass, throws an error with details if any fail.
{
  pkgs ? import <nixpkgs> {},
  lib ? pkgs.lib,
}: let
  nft = import ../../lib/nftables.nix {inherit lib;};

  # Test helper: assert that actual equals expected
  assertEq = name: expected: actual:
    if actual == expected
    then true
    else
      throw ''
        Test "${name}" failed:
          expected: ${builtins.toJSON expected}
          actual:   ${builtins.toJSON actual}
      '';

  # Run all tests and return true if all pass
  runTests = tests: let
    results = map (t: t.check) tests;
  in
    builtins.all (x: x == true) results;

  tests = [
    # ==================
    # Basic verdicts
    # ==================
    {
      name = "simple accept";
      check =
        assertEq "simple accept"
        ''iifname "eth0" accept''
        (nft.renderRule {
          iifname = "eth0";
          verdict = "accept";
        });
    }
    {
      name = "simple drop";
      check =
        assertEq "simple drop"
        ''oifname "wan0" drop''
        (nft.renderRule {
          oifname = "wan0";
          verdict = "drop";
        });
    }

    # ==================
    # Interface matching
    # ==================
    {
      name = "single interface";
      check =
        assertEq "single interface"
        ''iifname "eth0" accept''
        (nft.renderRule {
          iifname = "eth0";
          verdict = "accept";
        });
    }
    {
      name = "multiple interfaces";
      check =
        assertEq "multiple interfaces"
        ''iifname { "eth0", "eth1" } accept''
        (nft.renderRule {
          iifname = ["eth0" "eth1"];
          verdict = "accept";
        });
    }
    {
      name = "input and output interfaces";
      check =
        assertEq "input and output interfaces"
        ''iifname "lan0" oifname "wan0" accept''
        (nft.renderRule {
          iifname = "lan0";
          oifname = "wan0";
          verdict = "accept";
        });
    }

    # ==================
    # TCP/UDP port matching
    # ==================
    {
      name = "tcp dport string";
      check =
        assertEq "tcp dport string"
        ''tcp dport 22 accept''
        (nft.renderRule {
          tcp.dport = "22";
          verdict = "accept";
        });
    }
    {
      name = "tcp dport integer";
      check =
        assertEq "tcp dport integer"
        ''tcp dport 22 accept''
        (nft.renderRule {
          tcp.dport = 22;
          verdict = "accept";
        });
    }
    {
      name = "tcp sport and dport";
      check =
        assertEq "tcp sport and dport"
        ''tcp sport 1024 tcp dport 80 accept''
        (nft.renderRule {
          tcp.sport = 1024;
          tcp.dport = 80;
          verdict = "accept";
        });
    }
    {
      name = "udp dport";
      check =
        assertEq "udp dport"
        ''udp dport 53 accept''
        (nft.renderRule {
          udp.dport = 53;
          verdict = "accept";
        });
    }
    {
      name = "multiple ports";
      check =
        assertEq "multiple ports"
        ''tcp dport { 80, 443, 8080 } accept''
        (nft.renderRule {
          tcp.dport = [80 443 8080];
          verdict = "accept";
        });
    }

    # ==================
    # IPv4 matching
    # ==================
    {
      name = "ip saddr";
      check =
        assertEq "ip saddr"
        ''ip saddr 192.168.1.0/24 accept''
        (nft.renderRule {
          ip.saddr = "192.168.1.0/24";
          verdict = "accept";
        });
    }
    {
      name = "ip daddr";
      check =
        assertEq "ip daddr"
        ''ip daddr 10.0.0.1 accept''
        (nft.renderRule {
          ip.daddr = "10.0.0.1";
          verdict = "accept";
        });
    }
    {
      name = "ip saddr and daddr";
      check =
        assertEq "ip saddr and daddr"
        ''ip saddr 192.168.1.0/24 ip daddr 10.0.0.0/8 accept''
        (nft.renderRule {
          ip.saddr = "192.168.1.0/24";
          ip.daddr = "10.0.0.0/8";
          verdict = "accept";
        });
    }

    # ==================
    # IPv6 matching
    # ==================
    {
      name = "ip6 saddr";
      check =
        assertEq "ip6 saddr"
        ''ip6 saddr fd00::/8 accept''
        (nft.renderRule {
          ip6.saddr = "fd00::/8";
          verdict = "accept";
        });
    }
    {
      name = "ip6 daddr";
      check =
        assertEq "ip6 daddr"
        ''ip6 daddr 2001:db8::1 accept''
        (nft.renderRule {
          ip6.daddr = "2001:db8::1";
          verdict = "accept";
        });
    }

    # ==================
    # ICMP matching
    # ==================
    {
      name = "icmp type single";
      check =
        assertEq "icmp type single"
        ''icmp type echo-request accept''
        (nft.renderRule {
          icmp.type = "echo-request";
          verdict = "accept";
        });
    }
    {
      name = "icmp type multiple";
      check =
        assertEq "icmp type multiple"
        ''icmp type { echo-request, echo-reply } accept''
        (nft.renderRule {
          icmp.type = ["echo-request" "echo-reply"];
          verdict = "accept";
        });
    }
    {
      name = "icmpv6 type";
      check =
        assertEq "icmpv6 type"
        ''icmpv6 type { nd-neighbor-solicit, nd-neighbor-advert } accept''
        (nft.renderRule {
          icmpv6.type = ["nd-neighbor-solicit" "nd-neighbor-advert"];
          verdict = "accept";
        });
    }

    # ==================
    # Meta selectors
    # ==================
    {
      name = "meta l4proto";
      check =
        assertEq "meta l4proto"
        ''meta l4proto { tcp, udp } accept''
        (nft.renderRule {
          meta.l4proto = ["tcp" "udp"];
          verdict = "accept";
        });
    }
    {
      name = "meta mark";
      check =
        assertEq "meta mark"
        ''meta mark 0x1 accept''
        (nft.renderRule {
          meta.mark = "0x1";
          verdict = "accept";
        });
    }

    # ==================
    # Connection tracking
    # ==================
    {
      name = "ct state single";
      check =
        assertEq "ct state single"
        ''ct state established accept''
        (nft.renderRule {
          ct.state = "established";
          verdict = "accept";
        });
    }
    {
      name = "ct state multiple";
      check =
        assertEq "ct state multiple"
        ''ct state { established, related } accept''
        (nft.renderRule {
          ct.state = ["established" "related"];
          verdict = "accept";
        });
    }

    # ==================
    # NAT verdicts
    # ==================
    {
      name = "dnat verdict";
      check =
        assertEq "dnat verdict"
        ''iifname "wan0" tcp dport 8080 dnat to 10.0.0.1:80''
        (nft.renderRule {
          iifname = "wan0";
          tcp.dport = 8080;
          verdict.dnat = "10.0.0.1:80";
        });
    }
    {
      name = "snat verdict";
      check =
        assertEq "snat verdict"
        ''ip saddr 192.168.1.0/24 snat to 203.0.113.1''
        (nft.renderRule {
          ip.saddr = "192.168.1.0/24";
          verdict.snat = "203.0.113.1";
        });
    }
    {
      name = "redirect verdict";
      check =
        assertEq "redirect verdict"
        ''tcp dport 80 redirect to 8080''
        (nft.renderRule {
          tcp.dport = 80;
          verdict.redirect = 8080;
        });
    }
    {
      name = "reject verdict boolean";
      check =
        assertEq "reject verdict boolean"
        ''reject''
        (nft.renderRule {verdict.reject = true;});
    }
    {
      name = "reject verdict with type";
      check =
        assertEq "reject verdict with type"
        ''reject with icmp-port-unreachable''
        (nft.renderRule {verdict.reject = "icmp-port-unreachable";});
    }

    # ==================
    # Masquerade
    # ==================
    {
      name = "masquerade";
      check =
        assertEq "masquerade"
        ''oifname "wan0" masquerade''
        (nft.renderRule {
          oifname = "wan0";
          masquerade = true;
        });
    }

    # ==================
    # Logging
    # ==================
    {
      name = "log boolean";
      check =
        assertEq "log boolean"
        ''log drop''
        (nft.renderRule {
          log = true;
          verdict = "drop";
        });
    }
    {
      name = "log with prefix";
      check =
        assertEq "log with prefix"
        ''log prefix "DROPPED: " drop''
        (nft.renderRule {
          log = "DROPPED: ";
          verdict = "drop";
        });
    }

    # ==================
    # Counter
    # ==================
    {
      name = "counter";
      check =
        assertEq "counter"
        ''iifname "eth0" counter accept''
        (nft.renderRule {
          iifname = "eth0";
          counter = true;
          verdict = "accept";
        });
    }

    # ==================
    # Rate limiting
    # ==================
    {
      name = "rate limit";
      check =
        assertEq "rate limit"
        ''limit rate 10/second accept''
        (nft.renderRule {
          limit = "10/second";
          verdict = "accept";
        });
    }
    {
      name = "rate limit with burst";
      check =
        assertEq "rate limit with burst"
        ''limit rate 10/second burst 20 packets accept''
        (nft.renderRule {
          limit = "10/second burst 20 packets";
          verdict = "accept";
        });
    }

    # ==================
    # Comments
    # ==================
    {
      name = "comment";
      check =
        assertEq "comment"
        ''iifname "eth0" tcp dport 22 accept comment "Allow SSH"''
        (nft.renderRule {
          iifname = "eth0";
          tcp.dport = 22;
          verdict = "accept";
          comment = "Allow SSH";
        });
    }

    # ==================
    # TCP flags
    # ==================
    {
      name = "tcp flags";
      check =
        assertEq "tcp flags"
        ''tcp flags syn accept''
        (nft.renderRule {
          tcp.flags = "syn";
          verdict = "accept";
        });
    }
    {
      name = "tcp flags multiple";
      check =
        assertEq "tcp flags multiple"
        ''tcp flags { syn, ack } accept''
        (nft.renderRule {
          tcp.flags = ["syn" "ack"];
          verdict = "accept";
        });
    }

    # ==================
    # Negation
    # ==================
    {
      name = "negated match";
      check =
        assertEq "negated match"
        ''ip saddr != 192.168.1.0/24 drop''
        (nft.renderRule {
          ip.saddr = {not = "192.168.1.0/24";};
          verdict = "drop";
        });
    }

    # ==================
    # Complex rules
    # ==================
    {
      name = "complex forward rule";
      check =
        assertEq "complex forward rule"
        ''iifname "lan0" ip saddr 192.168.1.0/24 oifname "wan0" tcp dport 443 ct state new counter accept comment "Allow HTTPS out"''
        (nft.renderRule {
          iifname = "lan0";
          ip.saddr = "192.168.1.0/24";
          oifname = "wan0";
          tcp.dport = 443;
          ct.state = "new";
          counter = true;
          verdict = "accept";
          comment = "Allow HTTPS out";
        });
    }
    {
      name = "complex nat rule";
      check =
        assertEq "complex nat rule"
        ''iifname "wan0" tcp dport { 80, 443 } dnat to 10.0.0.10''
        (nft.renderRule {
          iifname = "wan0";
          tcp.dport = [80 443];
          verdict.dnat = "10.0.0.10";
        });
    }

    # ==================
    # Raw string passthrough
    # ==================
    {
      name = "raw string passthrough";
      check =
        assertEq "raw string passthrough"
        ''tcp flags syn tcp option maxseg size set rt mtu''
        (nft.renderRule "tcp flags syn tcp option maxseg size set rt mtu");
    }

    # ==================
    # Multiple rules rendering
    # ==================
    {
      name = "multiple rules";
      check =
        assertEq "multiple rules"
        ''          iifname "eth0" accept
          iifname "eth1" drop''
        (nft.rulesToString [
          {
            iifname = "eth0";
            verdict = "accept";
          }
          {
            iifname = "eth1";
            verdict = "drop";
          }
        ]);
    }
    {
      name = "multiple rules with indent";
      check =
        assertEq "multiple rules with indent"
        ''          iifname "eth0" accept
              iifname "eth1" drop''
        (nft.rulesToStringIndented "    " [
          {
            iifname = "eth0";
            verdict = "accept";
          }
          {
            iifname = "eth1";
            verdict = "drop";
          }
        ]);
    }
    {
      name = "mixed structured and raw rules";
      check =
        assertEq "mixed structured and raw rules"
        ''          iifname "eth0" tcp dport 22 accept
          raw nftables expression here
          iifname "eth1" drop''
        (nft.rulesToString [
          {
            iifname = "eth0";
            tcp.dport = 22;
            verdict = "accept";
          }
          "raw nftables expression here"
          {
            iifname = "eth1";
            verdict = "drop";
          }
        ]);
    }
  ];

  # When running as a flake check, wrap in a derivation
  testResult =
    if runTests tests
    then "All ${toString (builtins.length tests)} tests passed!"
    else throw "Some tests failed";
in
  # Return a derivation for flake checks
  pkgs.runCommand "nftables-dsl-tests" {
    preferLocalBuild = true;
  } ''
    # Run the tests by evaluating the result
    echo "${testResult}" > $out
  ''
