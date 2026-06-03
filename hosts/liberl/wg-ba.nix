{
  config,
  pkgs,
  lib,
  ...
}: let
  # liberl's own wg interface address, on the remote's wg subnet
  # (192.168.127.0/24). /32 + the explicit peer AllowedIPs below keeps routing
  # point-to-point. The remote must list this as liberl's peer AllowedIPs.
  ifaceAddress = "192.168.127.200/32";

  # What liberl routes over the tunnel: the remote wg peer and the backup SSH
  # target behind it (known literals — external box, not in our registry).
  allowedIPs = "192.168.127.1/32, 192.168.0.35/32";

  # The rendered wg-quick conf (sops template — keeps the DDNS endpoint and the
  # private key out of the nix store).
  confPath = config.sops.templates."wg-ba.conf".path;

  # Re-resolve the DDNS endpoint and re-point the peer when the handshake goes
  # stale. wg-quick only resolves Endpoint once at `up`; a DDNS flap otherwise
  # silently breaks the tunnel until the next reload. wireguard-tools does not
  # ship its contrib/reresolve-dns script in the nix package output, so this is
  # a minimal inline equivalent driven off the rendered conf's Endpoint line.
  reresolveScript = pkgs.writeShellScript "wg-ba-reresolve-dns" ''
    set -euo pipefail
    conf="${confPath}"

    # Pull the Endpoint host:port straight from the rendered conf (it holds the
    # DDNS hostname; the private key etc. stay untouched).
    endpoint="$(${pkgs.gnused}/bin/sed -n 's/^[[:space:]]*Endpoint[[:space:]]*=[[:space:]]*//p' "$conf" | tr -d '[:space:]')"
    if [ -z "$endpoint" ]; then
      echo "wg-ba-reresolve: no Endpoint in $conf" >&2
      exit 0
    fi

    # Re-resolve only when the last handshake is stale (>135s) or never happened,
    # so we don't thrash the peer endpoint on every tick.
    latest="$(${pkgs.wireguard-tools}/bin/wg show wg-ba latest-handshakes 2>/dev/null | ${pkgs.gawk}/bin/awk '{print $2}' | sort -n | tail -1)"
    latest="''${latest:-0}"
    now="$(date +%s)"
    if [ "$latest" -ne 0 ] && [ "$((now - latest))" -lt 135 ]; then
      exit 0
    fi

    # The peer pubkey for `wg set` comes from the live interface (single peer),
    # so the script needs no build-time key — the pubkey lives only in sops.
    pubkey="$(${pkgs.wireguard-tools}/bin/wg show wg-ba peers 2>/dev/null | head -n1 || true)"
    if [ -z "$pubkey" ]; then
      echo "wg-ba-reresolve: no peer configured on wg-ba" >&2
      exit 0
    fi

    ${pkgs.wireguard-tools}/bin/wg set wg-ba peer "$pubkey" endpoint "$endpoint"
  '';
in {
  # liberl's wg private key. Default owner/mode (root:0400) is fine — wg-quick
  # runs as root.
  sops.secrets."wg-ba-privatekey" = {};

  # The remote DDNS endpoint as host:port (kept in sops so the DDNS name never
  # lands in the nix store).
  sops.secrets."wg-ba-endpoint" = {};

  # The remote peer's public key — kept in sops alongside the other offsite
  # connection details (not a secret per se, but keeps the peer's identity out of
  # the repo). Used via placeholder in the template below; the reresolve script
  # reads the live pubkey off the interface, so it isn't needed at build time.
  sops.secrets."wg-ba-publickey" = {};

  # Render the whole wg-quick conf from the placeholders. configFile mode below
  # consumes this — nothing sensitive in the store.
  sops.templates."wg-ba.conf".content = ''
    [Interface]
    PrivateKey = ${config.sops.placeholder."wg-ba-privatekey"}
    Address = ${ifaceAddress}

    [Peer]
    PublicKey = ${config.sops.placeholder."wg-ba-publickey"}
    Endpoint = ${config.sops.placeholder."wg-ba-endpoint"}
    AllowedIPs = ${allowedIPs}
    PersistentKeepalive = 25
  '';

  # configFile mode only — the whole tunnel comes from the rendered file; do not
  # also declare address/peers here.
  networking.wg-quick.interfaces.wg-ba.configFile = confPath;

  # Phase 2 — tunnel-scoped egress filter. The nftables backend is already on for
  # liberl (modules/common/firewall.nix); this adds a separate table that
  # constrains ONLY the wg-ba interface (policy accept → liberl's other traffic is
  # untouched, no NAS-breakage risk). Over the tunnel liberl may reach only the
  # backup host on SSH; the peer's own address (192.168.127.1) routes but gets no
  # allow. Inbound on wg-ba is dropped — belt-and-suspenders on top of the
  # source-restricted input firewall, so a future globally-opened port can't be
  # exposed to the remote. (Established/related return traffic for liberl's own
  # backups is accepted in both directions.)
  networking.nftables.tables.wgBa = {
    family = "inet";
    content = ''
      chain output {
        type filter hook output priority 0; policy accept;
        oifname "wg-ba" ct state established,related accept
        oifname "wg-ba" ip daddr 192.168.0.35 tcp dport 22 accept
        oifname "wg-ba" drop
      }
      chain input {
        type filter hook input priority 0; policy accept;
        iifname "wg-ba" ct state established,related accept
        iifname "wg-ba" drop
      }
    '';
  };

  # Ordering: the conf is rendered by sops-nix. On this host sops-nix runs as an
  # activation script (`sops.useSystemdActivation = false`), so the rendered
  # template is already in place before any service starts; there is no
  # `sops-install-secrets.service` to order against in that mode. The `after`/
  # `wants` below are a no-op today but make the dependency correct if the host
  # ever flips to systemd-activation mode; the ConditionPathExists is the actual
  # guard — wg-quick won't try to bring the tunnel up without the rendered conf.
  systemd.services.wg-quick-wg-ba = {
    after = ["sops-install-secrets.service"];
    wants = ["sops-install-secrets.service"];
    unitConfig.ConditionPathExists = confPath;
  };

  # Re-resolve the DDNS endpoint roughly every 5 minutes (and shortly after
  # boot) so the tunnel recovers from a remote endpoint change on its own.
  systemd.services.wg-ba-reresolve-dns = {
    description = "Re-resolve wg-ba DDNS endpoint";
    after = ["wg-quick-wg-ba.service"];
    wants = ["wg-quick-wg-ba.service"];
    # coreutils for the bare date/tr/sort/tail in the reresolve script (wg/sed/awk
    # are already fully-pathed) — keeps the unit's PATH hermetic rather than
    # relying on the ambient system PATH.
    path = [pkgs.coreutils];
    serviceConfig = {
      Type = "oneshot";
      ExecStart = reresolveScript;
    };
  };

  systemd.timers.wg-ba-reresolve-dns = {
    description = "Periodic wg-ba DDNS endpoint re-resolution";
    wantedBy = ["timers.target"];
    timerConfig = {
      OnBootSec = "120s";
      OnUnitActiveSec = "300s";
      Unit = "wg-ba-reresolve-dns.service";
    };
  };
}
