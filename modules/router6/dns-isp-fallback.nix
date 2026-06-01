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
    systemd.services."kresd-isp-fallback-render" = {
      description = "Render kresd ISP DNS fallback from WAN DHCP lease";
      wantedBy = ["kresd.target"];
      before = ["kresd.target"];
      after = ["systemd-networkd-wait-online@${wan}.service"];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = renderScript;

        # systemd owns /run/knot-resolver. Created before ExecStart with
        # the right user/mode; kept alive across kresd@*.service restarts
        # (Preserve=yes) so the lease-watch path unit can re-render even
        # when a transient kresd outage has torn down its own
        # RuntimeDirectory. Runs as knot-resolver so the written file is
        # owned by the same user kresd reads it as.
        User = "knot-resolver";
        Group = "knot-resolver";
        RuntimeDirectory = "knot-resolver";
        RuntimeDirectoryMode = "0770";
        RuntimeDirectoryPreserve = "yes";
      };
    };

    # kresd's Lua config dofile()s /run/knot-resolver/isp-dns.lua at
    # config-load time, so the renderer above MUST complete before any
    # kresd instance starts. The render service's own `before =
    # ["kresd@.service"]` targets the template literal — systemd does
    # not propagate template-level Before= to instances, so on cold
    # boot under load kresd@1.service races the render and dies with
    # `cannot open /run/knot-resolver/isp-dns.lua`. Wire the dependency
    # in the other direction via the kresd@ template, which DOES
    # propagate to instances.
    #
    # `requires` (not `wants`): the render must be active before kresd
    # starts. The render script is robust — it ALWAYS produces a file,
    # falling back to the static upstream list when no lease is present
    # — so the "render fails -> kresd fails" cascade only triggers on a
    # real script bug. A previous iteration used `wants` to soften this,
    # but the actual failure mode we hit was "file doesn't exist on
    # deploy/restart" (the soft dependency let kresd start without the
    # render completing), which is worse than a clean cascade.
    #
    # RuntimeDirectoryPreserve=yes: nixpkgs's kresd@ template declares
    # RuntimeDirectory=knot-resolver without Preserve. Default behavior
    # tears down /run/knot-resolver when kresd@1 stops, wiping the
    # renderer-written isp-dns.lua. On next kresd@1 start, `requires=`
    # passes (renderer is still active via RemainAfterExit) so the
    # renderer doesn't re-run, kresd@1 finds the file gone, and dies
    # with `cannot open /run/knot-resolver/isp-dns.lua`. Preserving the
    # dir across kresd@ restarts matches the renderer's own Preserve=yes
    # so both units agree.
    systemd.services."kresd@" = {
      after = ["kresd-isp-fallback-render.service"];
      requires = ["kresd-isp-fallback-render.service"];
      serviceConfig.RuntimeDirectoryPreserve = "yes";
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
        # Drive the render via its own service so the render always runs
        # under the same User + RuntimeDirectory setup (instead of as
        # root with no managed runtime dir). `restart` (not start) is
        # what we want for an oneshot-RemainAfterExit unit: it re-runs
        # ExecStart even though the service is "active".
        ExecStart = [
          "${pkgs.systemd}/bin/systemctl restart kresd-isp-fallback-render.service"
          "${pkgs.systemd}/bin/systemctl try-restart kresd.target"
        ];
      };
    };
  };
}
