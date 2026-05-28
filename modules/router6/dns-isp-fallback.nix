{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.router6;
  fallback = cfg.dns.fallbackUpstream;
  wan = cfg.dns.fallbackFromLease;

  staticLua = let
    quoted = lib.concatMapStringsSep ", " (a: "'${a}'") fallback;
  in "return { ${quoted} }\n";

  # Writes the lease-derived (or static) fallback list into kresd's runtime
  # dir. kresd reads via dofile() at config load time, so a restart is required
  # to pick up changes; we accept this since lease changes are rare and brief.
  renderScript = pkgs.writeShellScript "kresd-isp-fallback-render" ''
    set -eu
    iface=${lib.escapeShellArg wan}
    out=/run/knot-resolver/isp-dns.lua
    fallback_static=${lib.escapeShellArg staticLua}

    write_static() {
      printf '%s' "$fallback_static" > "$out.tmp"
      chmod 0644 "$out.tmp"
      mv "$out.tmp" "$out"
    }

    if [ ! -e /sys/class/net/"$iface"/ifindex ]; then
      write_static
      exit 0
    fi

    ifindex=$(cat /sys/class/net/"$iface"/ifindex)
    lease=/run/systemd/netif/leases/"$ifindex"

    if [ ! -e "$lease" ]; then
      write_static
      exit 0
    fi

    dns_line=$(grep -E '^DNS=' "$lease" || true)
    if [ -z "$dns_line" ]; then
      write_static
      exit 0
    fi

    addrs=''${dns_line#DNS=}
    quoted=""
    for a in $addrs; do
      if [ -n "$quoted" ]; then quoted="$quoted, "; fi
      quoted="$quoted'$a'"
    done

    if [ -z "$quoted" ]; then
      write_static
      exit 0
    fi

    printf "return { %s }\n" "$quoted" > "$out.tmp"
    chmod 0644 "$out.tmp"
    mv "$out.tmp" "$out"
  '';
in {
  config = lib.mkIf (cfg.enable && wan != null) {
    systemd.tmpfiles.rules = [
      "d /run/knot-resolver 0770 knot-resolver knot-resolver - -"
    ];

    systemd.services."kresd-isp-fallback-render" = {
      description = "Render kresd ISP DNS fallback from WAN DHCP lease";
      wantedBy = ["kresd.target"];
      before = ["kresd.target" "kresd@.service"];
      after = ["systemd-networkd-wait-online@${wan}.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = renderScript;
      };
    };

    systemd.paths."kresd-isp-fallback" = {
      description = "Watch WAN DHCP lease for DNS changes";
      wantedBy = ["multi-user.target"];
      pathConfig = {
        # systemd-networkd writes leases under this directory keyed by ifindex.
        # Watching the parent survives atomic-rename updates of any lease file;
        # the renderer narrows back to the WAN ifindex.
        PathChanged = "/run/systemd/netif/leases";
        MakeDirectory = false;
      };
    };

    systemd.services."kresd-isp-fallback" = {
      description = "Re-render kresd ISP DNS fallback and restart kresd";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = [
          renderScript.outPath
          "${pkgs.systemd}/bin/systemctl try-restart kresd.target"
        ];
      };
    };
  };
}
