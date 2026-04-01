# Display/formatting helpers for the network registry.
# Consumed by apps/netinfo.nix and apps/hostinfo.nix via flake lib exports.
# Separated from network.nix to keep data logic distinct from presentation.
{
  lib,
  hosts,
  domainsForHost,
}: let
  # Shared padding helper
  pad = n: s: let
    padLen = n - builtins.stringLength s;
  in
    if padLen <= 0
    then s
    else s + lib.fixedWidthString padLen " " "";

  # --- netinfo: network host summary ---

  header = "${pad 18 "Host"}${pad 18 "Zone"}${pad 18 "IPv4"}IPv6";
  separator = builtins.concatStringsSep "" (builtins.genList (_: "-") (builtins.stringLength header));

  row = name: h: "${pad 18 name}${pad 18 h.zoneName}${pad 18 h.ipv4}${h.ipv6 or ""}";

  hostList = lib.mapAttrsToList lib.nameValuePair hosts;
  hostsByZone = builtins.groupBy (e: e.value.zoneName) hostList;

  renderZone = _zoneName: entries:
    lib.concatMapStringsSep "\n" (e: row e.name e.value) entries;

  summary =
    lib.concatStringsSep "\n\n" (
      [header separator]
      ++ lib.mapAttrsToList renderZone hostsByZone
    )
    + "\n";

  markdownRow = name: h: "| ${name} | ${h.zoneName} | `${h.ipv4}` | ${
    if h ? ipv6
    then "`${h.ipv6}`"
    else ""
  } |";

  markdown =
    ''
      # Network Host Registry

      > **Auto-generated from `lib/common/data/network.nix`.** Do not edit manually.
      > Regenerate with: `nix run .#netinfo -- --generate-docs`

      | Host | Zone | IPv4 | IPv6 |
      |------|------|------|------|
    ''
    + lib.concatStringsSep "\n" (lib.mapAttrsToList markdownRow hosts)
    + "\n";

  # --- hostinfo: host domain summary ---

  hostinfoHeader = "${pad 18 "Host"}${pad 18 "IPv4"}${pad 45 "IPv6"}Domains";
  hostinfoSeparator = builtins.concatStringsSep "" (builtins.genList (_: "-") (builtins.stringLength hostinfoHeader));

  hostinfoRow = name: h: let
    domains = domainsForHost name;
  in "${pad 18 name}${pad 18 h.ipv4}${pad 45 (h.ipv6 or "")}${lib.concatStringsSep ", " domains}";

  hostinfoRenderZone = zoneName: entries:
    "# ${zoneName}\n"
    + lib.concatMapStringsSep "\n" (e: hostinfoRow e.name e.value) entries;

  hostinfoSummary =
    lib.concatStringsSep "\n\n" (
      [hostinfoHeader hostinfoSeparator]
      ++ lib.mapAttrsToList hostinfoRenderZone hostsByZone
    )
    + "\n";

  hostinfoMarkdownRow = name: h: let
    domains = domainsForHost name;
  in "| ${name} | `${h.ipv4}` | ${
    if h ? ipv6
    then "`${h.ipv6}`"
    else ""
  } | ${lib.concatStringsSep ", " (map (d: "`${d}`") domains)} |";

  hostinfoMarkdown =
    ''
      # Host Domain Registry

      > **Auto-generated from `lib/common/data/network.nix`.** Do not edit manually.
      > Regenerate with: `nix run .#hostinfo -- --generate-docs`

      | Host | IPv4 | IPv6 | Domains |
      |------|------|------|---------|
    ''
    + lib.concatStringsSep "\n" (lib.mapAttrsToList hostinfoMarkdownRow hosts)
    + "\n";
in {
  inherit
    summary
    markdown
    hostinfoSummary
    hostinfoMarkdown
    ;
}
