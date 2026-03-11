# nftables DSL Library
#
# Provides structured Nix attribute sets for generating nftables rules.
# Rules can be either:
#   - Attribute sets (processed by this DSL)
#   - Raw strings (passed through unchanged as escape hatch)
#
# Example usage:
#   {
#     iifname = "eth0";
#     tcp.dport = "22";
#     verdict = "accept";
#     comment = "Allow SSH";
#   }
#   → iifname "eth0" tcp dport 22 accept comment "Allow SSH"
#
{lib}: let
  inherit (lib) concatStringsSep mapAttrsToList optionalString;
  inherit (builtins) isString isList hasAttr getAttr isInt isBool toString;

  # Quote a string for nftables (interface names, etc.)
  quote = s: ''"${s}"'';

  # Render a match value, handling different types:
  #   - string: passed through
  #   - int: converted to string
  #   - list: wrapped in { } brackets
  #   - { not = val }: negation
  #   - { vmap = { ... } }: value map
  renderMatch = match:
    if isString match
    then match
    else if isInt match
    then toString match
    else if isList match
    then "{ ${concatStringsSep ", " (map renderMatchItem match)} }"
    else if hasAttr "not" match
    then "!= ${renderMatch match.not}"
    else if hasAttr "vmap" match
    then "vmap { ${concatStringsSep ", " (
      mapAttrsToList (n: v: "${n} : ${v}") match.vmap
    )} }"
    else abort "nftables: invalid match value: ${builtins.toJSON match}";

  # Render a single item in a match list (handles ints in lists)
  renderMatchItem = item:
    if isInt item
    then toString item
    else item;

  # Render an interface name (auto-quotes strings and lists)
  renderIfName = ifName:
    if isString ifName
    then quote ifName
    else if isList ifName
    then "{ ${concatStringsSep ", " (map quote ifName)} }"
    else abort "nftables: invalid interface name: ${builtins.toJSON ifName}";

  # Render a sub-rule for protocol matching (e.g., tcp dport 22)
  renderSubRule = proto: attr: set:
    if hasAttr attr set && getAttr attr set != null
    then "${proto} ${attr} ${renderMatch (getAttr attr set)}"
    else null;

  # Render verdict, handling different types
  renderVerdict = ver:
    if isString ver
    then ver
    else if hasAttr "dnat" ver
    then "dnat to ${ver.dnat}"
    else if hasAttr "snat" ver
    then "snat to ${ver.snat}"
    else if hasAttr "redirect" ver
    then "redirect to ${toString ver.redirect}"
    else if hasAttr "reject" ver
    then
      if isBool ver.reject
      then "reject"
      else "reject with ${ver.reject}"
    else abort "nftables: invalid verdict: ${builtins.toJSON ver}";

  # Render a log statement
  renderLog = log:
    if isBool log
    then
      (
        if log
        then "log"
        else null
      )
    else if isString log
    then ''log prefix "${log}"''
    else abort "nftables: invalid log value: ${builtins.toJSON log}";

  # Build a list of rule fragments, filtering out nulls
  buildFragments = fragments:
    builtins.filter (x: x != null) fragments;

  # The main rule renderer
  renderFormattedRule = {
    # Interface matching
    iifname ? null,
    oifname ? null,
    # IPv4 matching
    ip ? {},
    # IPv6 matching
    ip6 ? {},
    # TCP matching
    tcp ? {},
    # UDP matching
    udp ? {},
    # Transport header matching (protocol-agnostic, use with meta.l4proto)
    th ? {},
    # ICMP matching
    icmp ? {},
    # ICMPv6 matching
    icmpv6 ? {},
    # Meta matching (l4proto, mark, etc.)
    meta ? {},
    # Connection tracking
    ct ? {},
    # Rate limiting
    limit ? null,
    # Logging
    log ? null,
    # Counter
    counter ? false,
    # Verdict (accept, drop, { dnat = "..." }, etc.)
    verdict ? null,
    # Masquerade
    masquerade ? false,
    # Comment
    comment ? null,
  }:
    concatStringsSep " " (buildFragments [
      # Input interface
      (
        if iifname != null
        then "iifname ${renderIfName iifname}"
        else null
      )

      # Meta selectors
      (renderSubRule "meta" "l4proto" meta)
      (renderSubRule "meta" "mark" meta)
      (renderSubRule "meta" "nfproto" meta)

      # Layer 3: IPv4
      (renderSubRule "ip" "saddr" ip)
      (renderSubRule "ip" "daddr" ip)
      (renderSubRule "ip" "protocol" ip)

      # Layer 3: IPv6
      (renderSubRule "ip6" "saddr" ip6)
      (renderSubRule "ip6" "daddr" ip6)
      (renderSubRule "ip6" "nexthdr" ip6)

      # Output interface (placed after L3 matching)
      (
        if oifname != null
        then "oifname ${renderIfName oifname}"
        else null
      )

      # Layer 4: TCP
      (renderSubRule "tcp" "sport" tcp)
      (renderSubRule "tcp" "dport" tcp)
      (
        if hasAttr "flags" tcp && tcp.flags != null
        then "tcp flags ${renderMatch tcp.flags}"
        else null
      )

      # Layer 4: UDP
      (renderSubRule "udp" "sport" udp)
      (renderSubRule "udp" "dport" udp)

      # Layer 4: Transport header (protocol-agnostic dport/sport)
      (renderSubRule "th" "sport" th)
      (renderSubRule "th" "dport" th)

      # ICMP
      (renderSubRule "icmp" "type" icmp)
      (renderSubRule "icmp" "code" icmp)

      # ICMPv6
      (renderSubRule "icmpv6" "type" icmpv6)
      (renderSubRule "icmpv6" "code" icmpv6)

      # Connection tracking
      (renderSubRule "ct" "state" ct)
      (renderSubRule "ct" "mark" ct)

      # Rate limiting
      (
        if limit != null
        then "limit rate ${limit}"
        else null
      )

      # Logging (before verdict)
      (
        if log != null
        then renderLog log
        else null
      )

      # Counter
      (
        if counter
        then "counter"
        else null
      )

      # Verdict
      (
        if verdict != null
        then renderVerdict verdict
        else null
      )

      # Masquerade
      (
        if masquerade
        then "masquerade"
        else null
      )

      # Comment (always last)
      (
        if comment != null
        then ''comment "${comment}"''
        else null
      )
    ]);

  # Render a single rule (handles both structured and raw string rules)
  renderRule = rule:
    if isString rule
    then rule
    else renderFormattedRule rule;

  # Render a list of rules, joining with newlines and optional indentation
  renderRules = {
    rules,
    indent ? "  ",
  }:
    concatStringsSep "\n${indent}" (map renderRule rules);
in {
  # Re-export the individual functions for flexibility
  inherit quote renderMatch renderIfName renderVerdict renderRule renderRules;

  # Main entry point: render a list of rules
  rulesToString = rules:
    renderRules {
      inherit rules;
      indent = "";
    };

  # Render rules with custom indentation (for embedding in larger templates)
  rulesToStringIndented = indent: rules: renderRules {inherit rules indent;};
}
