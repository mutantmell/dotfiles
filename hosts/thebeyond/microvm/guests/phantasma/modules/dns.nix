{
  config,
  pkgs,
  ...
}: let
  net = pkgs.mmell.lib.data.network;
  inherit (net.forHost "phantasma") host zone;
in {
  networking.firewall.allowedUDPPorts = [
    53 # DNS (Unbound)
  ];
  networking.firewall.allowedTCPPorts = [
    53 # DNS (Unbound)
  ];

  # NixOS's networkd module defaults services.resolved.enable=true, which
  # binds 127.0.0.53:53 and (more importantly) rewrites /etc/resolv.conf to
  # point at that stub — both of which we need to keep clear so Unbound can
  # own 127.0.0.1:53 and libc resolves through it.
  services.resolved.enable = false;

  # libc -> 127.0.0.1:53 -> Unbound directly.
  networking.nameservers = ["127.0.0.1"];

  # Unbound - recursive DNS resolver with split-horizon. This is the single
  # resolver phantasma exposes: thebeyond's kresd forwards here over brMGMT,
  # and phantasma's own libc resolves through it on loopback.
  #
  # Ad-blocking is intentionally NOT done here. It lives in a separate Blocky
  # resolver outside thebeyond's kresd cache so blocked answers can never
  # poison the shared cache that fronts every VLAN (the failure mode that
  # made the old per-VLAN Blocky bypass leak across clients).
  #
  # DNSSEC validation is intentionally ON: this is the recursive resolver in
  # the chain. The router-side kresd-fragility note in
  # hosts/thebeyond/router.nix is specific to kresd's ta_update trust-anchor
  # refresh, not to Unbound.
  services.unbound = {
    enable = true;
    settings = {
      server = {
        # Loopback for libc, and the brMGMT addresses for thebeyond's kresd.
        # Port 53 throughout — there is no longer a separate :5335 endpoint
        # (that existed only for the old GUEST-VLAN no-block bypass).
        interface = [
          "127.0.0.1"
          "${host.ipv4}"
          "${host.ipv6}"
        ];
        port = 53;
        # The brMGMT addresses are statically assigned by networkd; on a cold
        # boot Unbound can start before they land. ip-freebind lets it bind
        # those addresses regardless, so a missing/late address doesn't fail
        # the whole service (one unbindable interface otherwise aborts
        # startup, which would take down libc's 127.0.0.1:53 resolver too). It
        # does not widen the bind — Unbound still listens only on these
        # addresses.
        ip-freebind = true;
        # Defense in depth alongside the firewall: only loopback (libc) and
        # thebeyond's brMGMT gateway (kresd) may query Unbound. Everything
        # else is refused even if it reaches the socket.
        access-control = [
          "127.0.0.0/8 allow"
          "::1 allow"
          "${zone.gateway4} allow" # thebeyond brMGMT (kresd)
          "${zone.gateway6} allow"
          "0.0.0.0/0 refuse"
          "::/0 refuse"
        ];
        aggressive-nsec = true;

        # Recover quickly from network transitions. Default infra-host-ttl
        # of 900s means a router/uplink flap can blackhole recursion for 15
        # minutes after Unbound marks roots/auths unreachable. 60s keeps
        # the dead-state window short without meaningfully increasing probe
        # traffic on a homelab.
        infra-host-ttl = 60;

        # Cache sized for the whole homelab — Unbound's defaults (4M each)
        # are too tight for a recursive resolver that fronts every device's
        # queries, leading to repeated cold-cache fetches on first-connect.
        msg-cache-size = "64m";
        rrset-cache-size = "128m";

        # Graceful degradation during upstream outages. serve-expired
        # returns cached records past their TTL only when a fresh fetch is
        # actually slow/failing (client-timeout gate), not as a routine
        # optimization. Stale answers are capped at 1 day and tagged with
        # a short reply TTL so clients re-ask once upstream recovers.
        serve-expired = true;
        serve-expired-client-timeout = 1800;
        serve-expired-ttl = 86400;
        serve-expired-reply-ttl = 30;
        prefetch = true;

        # Split-horizon DNS zones
        local-zone = [
          ''"mutantmell.net." transparent'' # split-horizon: local overrides, rest forwarded
          ''"internal.mutantmell.net." static'' # canonical internal: authoritative, never forwards
          ''"internal." static'' # short alias: authoritative, never forwards
        ];
        local-data =
          # Standard host records (<name>.internal.mutantmell.net + <name>.internal),
          # derived from the network registry (net.dnsHosts) so a newly-added host
          # resolves automatically. Opt a host out via dnsExcludedHosts in network.nix.
          net.mkUnboundLocalData net.dnsHosts
          # Alias records (split-horizon, backward-compat, service aliases)
          # sourced from hostAliases in network.nix
          ++ net.mkUnboundAliasData net.dnsHosts;
      };
      remote-control.control-enable = true;
    };
  };

  environment.systemPackages = with pkgs; [
    bind # for dig/nslookup debugging
  ];
}
