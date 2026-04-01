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

      extraConfig = let
        primaryServers = concatStringsSep ", " (map (s: "'${s}'") cfg.dns.upstream);
        staticFallback = concatStringsSep ", " (map (s: "'${s}'") cfg.dns.fallback);
        hasStaticFallback = cfg.dns.fallback != [] && cfg.dns.fallback != cfg.dns.upstream;
        hasPrimary = cfg.dns.upstream != [];
        useDHCP = cfg.dns.useDHCPFallback;
      in ''
        modules.load('policy')

        ${optionalString (hasPrimary && (useDHCP || hasStaticFallback)) ''
          -- Primary DNS with fallback support
          local primary_failures = 0
          local last_primary_success = os.time()
          local primary_down = false
          local PRIMARY_THRESHOLD = 3      -- failures before switching
          local PRIMARY_RETRY = 30         -- seconds before retrying primary

          local primary = policy.FORWARD({${primaryServers}})

          -- Read DHCP-provided DNS servers from lease file
          local function get_dhcp_dns()
            local servers = {}
            local f = io.open('/run/kresd/dhcp-dns', 'r')
            if f then
              for line in f:lines() do
                local ip = line:match('^%s*(.-)%s*$')  -- trim whitespace
                if ip and ip ~= "" then
                  table.insert(servers, ip)
                end
              end
              f:close()
            end
            return servers
          end

          local function get_fallback()
            ${
            if useDHCP
            then ''
              local dhcp_servers = get_dhcp_dns()
              if #dhcp_servers > 0 then
                return policy.FORWARD(dhcp_servers)
              end
            ''
            else ""
          }
            ${
            if hasStaticFallback
            then ''
              return policy.FORWARD({${staticFallback}})
            ''
            else ''
              return nil
            ''
          }
          end

          policy.add(function(state, req)
            -- If primary is marked down, check if we should retry
            if primary_down then
              if os.time() - last_primary_success > PRIMARY_RETRY then
                primary_down = false
                primary_failures = 0
              else
                local fb = get_fallback()
                if fb then return fb(state, req) end
              end
            end

            -- Try primary
            local result = primary(state, req)
            if result then
              last_primary_success = os.time()
              primary_failures = 0
              return result
            else
              primary_failures = primary_failures + 1
              if primary_failures >= PRIMARY_THRESHOLD then
                primary_down = true
                log('[dns] Primary DNS unavailable, switching to fallback')
              end
              local fb = get_fallback()
              if fb then return fb(state, req) end
            end
          end)
        ''}

        ${optionalString (hasPrimary && !useDHCP && !hasStaticFallback) ''
          -- Upstream DNS servers (no fallback configured)
          policy.add(policy.all(policy.FORWARD({${primaryServers}})))
        ''}

        ${optionalString (!hasPrimary && useDHCP) ''
          -- Use DHCP-provided DNS only
          local function get_dhcp_dns()
            local servers = {}
            local f = io.open('/run/kresd/dhcp-dns', 'r')
            if f then
              for line in f:lines() do
                local ip = line:match('^%s*(.-)%s*$')
                if ip and ip ~= "" then
                  table.insert(servers, ip)
                end
              end
              f:close()
            end
            return servers
          end

          policy.add(function(state, req)
            local servers = get_dhcp_dns()
            if #servers > 0 then
              return policy.FORWARD(servers)(state, req)
            end
          end)
        ''}

        ${optionalString (cfg.dns.localDomain != null) ''
          -- Block external resolution of local domain
          policy.add(policy.suffix(policy.DENY, policy.todnames({'${cfg.dns.localDomain}.'})))
        ''}

        -- DNSSEC (kresd has validation enabled by default with built-in root keys)
        ${optionalString (!cfg.dns.enableDNSSEC) ''
          trust_anchors.negative = { '.' }
        ''}

        -- Cache size (helps during outages)
        cache.size = 100 * MB
      '';
    };

    # Create directory for DHCP DNS file
    systemd.tmpfiles.rules = [
      "d /run/kresd 0755 knot-resolver knot-resolver -"
    ];

    # Service to extract DNS from DHCP lease and write to kresd-readable file
    systemd.services.kresd-dhcp-dns = mkIf cfg.dns.useDHCPFallback {
      description = "Extract DNS servers from DHCP lease for kresd";
      after = ["systemd-networkd.service"];
      wantedBy = ["multi-user.target"];

      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = let
          script = pkgs.writeShellScript "kresd-dhcp-dns" ''
            set -euo pipefail
            mkdir -p /run/kresd
            : > /run/kresd/dhcp-dns.tmp

            # Look for lease files from DHCP interfaces
            for lease in /run/systemd/netif/leases/*; do
              [ -f "$lease" ] || continue
              # Extract DNS servers from lease
              ${pkgs.gnugrep}/bin/grep -E '^DNS=' "$lease" 2>/dev/null | \
                ${pkgs.coreutils}/bin/cut -d= -f2 | \
                ${pkgs.coreutils}/bin/tr ' ' '\n' >> /run/kresd/dhcp-dns.tmp || true
            done

            # Deduplicate and move to final location
            ${pkgs.coreutils}/bin/sort -u /run/kresd/dhcp-dns.tmp > /run/kresd/dhcp-dns
            rm -f /run/kresd/dhcp-dns.tmp

            # Log what we found
            if [ -s /run/kresd/dhcp-dns ]; then
              echo "DHCP DNS servers: $(${pkgs.coreutils}/bin/tr '\n' ' ' < /run/kresd/dhcp-dns)"
            else
              echo "No DHCP DNS servers found"
            fi
          '';
        in "${script}";
      };
    };

    # Trigger DNS extraction when network changes
    systemd.paths.kresd-dhcp-dns = mkIf cfg.dns.useDHCPFallback {
      description = "Watch for DHCP lease changes";
      wantedBy = ["multi-user.target"];
      pathConfig = {
        PathChanged = "/run/systemd/netif/leases";
        Unit = "kresd-dhcp-dns.service";
      };
    };
  };
}
