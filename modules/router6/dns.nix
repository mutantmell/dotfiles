{
  config,
  lib,
  pkgs,
  ...
}: let
  cfg = config.router6;
  r6lib = import ./lib.nix {inherit cfg lib;};

  inherit
    (lib)
    mkIf
    optionalString
    concatStringsSep
    flatten
    ;
  inherit (r6lib) flattenTopology dnsInterfaces getEffectiveAddresses partitionAF;

  hasFallback = cfg.dns.fallbackFromLease != null;
  hasPrimary = cfg.dns.upstream != [];
  upstreamServers = concatStringsSep ", " (map (s: "'${s}'") cfg.dns.upstream);

  # kresd's policy.* identifiers are uppercase (FORWARD, STUB). The option
  # values are lowercase to match Nix-attr convention.
  primaryPolicyFn = "policy.${lib.toUpper cfg.dns.upstreamPolicy}";
  fallbackPolicyFn = "policy.${lib.toUpper cfg.dns.fallbackPolicy}";

  # kresd 5.x policy.FORWARD returns a closure that synchronously sets request
  # flags and the nslist, then returns `state`. It does NOT block on the
  # upstream answer, so the e3cf667 pattern `if primary(state, req) then ...`
  # cannot distinguish a healthy primary from a stalled one (it always sees
  # truthy). To get strict failover we drive an out-of-band health probe via
  # event.recurrent / worker.resolve and dispatch each user query based on a
  # cached primary_down flag. Probe outcome reads req.state / answer:rcode().
  strictFailoverLua = ''
    local primary_servers = {${upstreamServers}}
    local primary = ${primaryPolicyFn}(primary_servers)

    -- Renderer writes /run/knot-resolver/isp-dns.lua as `return {...}`. We
    -- load it once at config-load time; updates require kresd restart, which
    -- the renderer's reload service handles.
    local fallback_dns = dofile('/run/knot-resolver/isp-dns.lua')
    local fallback = ${fallbackPolicyFn}(fallback_dns)

    local PRIMARY_THRESHOLD = 3
    local PRIMARY_RETRY = 30
    local PROBE_INTERVAL_MS = 5 * 1000
    -- A hung primary (packets dropped, not refused) leaves resolve()
    -- pending indefinitely; without an explicit deadline the breaker can
    -- never accumulate failures. Treat a probe that hasn't returned in
    -- 2s as a failure.
    local PROBE_TIMEOUT_MS = 2 * 1000

    local primary_failures = 0
    local primary_down = false
    local last_trip_time = 0
    local probe_in_flight = false
    local probe_id = 0

    local function record_failure(reason)
      primary_failures = primary_failures + 1
      if not primary_down and primary_failures >= PRIMARY_THRESHOLD then
        primary_down = true
        last_trip_time = os.time()
        log('[router6-dns] primary unhealthy (' .. reason .. '), switching to fallback')
      end
    end

    local function record_success()
      if primary_down then
        log('[router6-dns] primary recovered, resetting breaker')
      end
      primary_failures = 0
      primary_down = false
    end

    local function probe_finish(answer, _)
      if not probe_in_flight then return end
      probe_in_flight = false
      if answer ~= nil then
        local rc = answer:rcode()
        if rc == kres.rcode.NOERROR or rc == kres.rcode.NXDOMAIN then
          record_success()
          return
        end
      end
      record_failure('probe SERVFAIL')
    end

    local function probe_primary()
      if probe_in_flight then return end
      if primary_down and (os.time() - last_trip_time) < PRIMARY_RETRY then
        return
      end
      probe_in_flight = true
      probe_id = probe_id + 1
      local my_id = probe_id
      event.after(PROBE_TIMEOUT_MS, function()
        if probe_in_flight and probe_id == my_id then
          probe_in_flight = false
          record_failure('probe timeout')
        end
      end)
      -- NO_CACHE bypasses kresd's cache so each probe actually reaches the
      -- upstream — without it, the first `.` SOA gets cached for the SOA's
      -- TTL (hours) and the breaker can never observe primary going down.
      resolve('.', kres.type.SOA, kres.class.IN, 'NO_CACHE', probe_finish)
    end

    policy.add(function(_, _)
      if probe_in_flight then
        return primary
      end
      if primary_down then
        return fallback
      end
      return primary
    end)

    log('[router6-dns] strict-failover dispatcher loaded')
    event.after(0, probe_primary)
    event.recurrent(PROBE_INTERVAL_MS, probe_primary)
  '';
in {
  config = mkIf cfg.enable {
    services.kresd = {
      enable = true;
      listenPlain =
        [
          "127.0.0.1:53"
          "[::1]:53"
        ]
        ++ (flatten (map (
            iface: let
              ifaceData = lib.findFirst (i: i.name == iface) null flattenTopology;
              addrs =
                if ifaceData != null
                then getEffectiveAddresses ifaceData
                else [];
              split = partitionAF addrs;
            in
              (map (a: "${a.ip}:53") split.v4)
              ++ (map (a: "[${a.ip}]:53") split.v6)
          )
          dnsInterfaces));

      extraConfig = ''
        modules.load('policy')

        ${
          if hasPrimary && hasFallback
          then strictFailoverLua
          else if hasPrimary
          then ''
            policy.add(policy.all(${primaryPolicyFn}({${upstreamServers}})))
          ''
          else if hasFallback
          then ''
            local fallback_dns = dofile('/run/knot-resolver/isp-dns.lua')
            policy.add(policy.all(${fallbackPolicyFn}(fallback_dns)))
          ''
          else ""
        }

        ${optionalString (!cfg.dns.enableDNSSEC) ''
          -- knot-resolver >=5.7: there is a default trust anchor for `.`,
          -- and set_insecure refuses to mark a name as NTA when it already
          -- has a TA. Drop the TA first, then mark `.` insecure.
          trust_anchors.remove('.')
          trust_anchors.set_insecure({ '.' })
        ''}
        ${optionalString cfg.dns.enableDNSSEC ''
          -- Pin the IANA root KSK from nixpkgs (dns-root-data) and load it
          -- in read-only mode. readonly=true sets managed=false internally,
          -- which keeps ta_update loaded but disables its RFC 5011 on-disk
          -- writes. The remove('.') call is for symmetry with the
          -- set_insecure branch above and to silence the "TA already exists"
          -- warning add_file would otherwise emit. KSK rolls roughly once
          -- per decade — a nixpkgs bump picks up the new revision.
          trust_anchors.remove('.')
          trust_anchors.add_file('${pkgs.dns-root-data}/root.key', true)
        ''}

        cache.size = 100 * MB
      '';
    };
  };
}
