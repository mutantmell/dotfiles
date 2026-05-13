# AdGuard → Blocky Migration on Phantasma

## Why now

Two converging reasons:

1. **Pre-existing intent.** `llm-notes/reports/self-hosting-recommendations.md` already
   recommends Blocky over AdGuard for this homelab: declarative YAML config tracked in
   git, native Prometheus metrics, smaller footprint (matters on phantasma's 512 MB),
   no mutable web-UI state to drift from declarations.
2. **Active debugging friction.** A current `dig @10.91.10.10 google.com` timeout has
   no local reproduction path — every diagnosis step requires the user to run
   commands manually on phantasma and report back. AdGuard's mutable
   `/var/lib/private/AdGuardHome/AdGuardHome.yaml` + first-run-wizard state machine
   resist VM testing. Blocky's pure declarative config does not.

The migration is small. The test infrastructure that comes with it is the real win.

## Scope

In:

- Replace `services.adguardhome` with `services.blocky` on phantasma.
- Keep Unbound on `127.0.0.1:5335` as recursive resolver (no change to split-horizon zones).
- Expose Blocky's `/metrics` endpoint and wire into existing Prometheus scraping (if quick).
- Two new tests (see below).

Out:

- Per-client groups / API kill-switch (deferred — separate change once basic stack works).
- AdGuard data migration. Blocklists are re-declared from the same upstream sources;
  query logs are not migrated. The old `/var/lib/private/AdGuardHome` directory in
  the persist volume becomes orphaned and can be cleaned up later.

## Target config shape

`hosts/thebeyond/microvm/guests/phantasma/modules/dns.nix`:

```nix
services.blocky = {
  enable = true;
  settings = {
    ports.dns = "0.0.0.0:53";
    ports.http = "127.0.0.1:4000";   # Prometheus metrics + REST API (loopback only)

    upstreams.groups.default = ["127.0.0.1:5335"];   # local Unbound

    blocking = {
      denylists.ads = [
        "https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"
        # plus whatever sources we used in AdGuard
      ];
      clientGroupsBlock.default = ["ads"];
    };

    customDNS.mapping = {
      # split-horizon — but most internal names are resolved by Unbound via
      # local-zone, so customDNS only carries records that need to short-circuit
      # before forwarding to Unbound. Likely empty initially.
    };

    prometheus.enable = true;

    log = {
      level = "info";
      format = "json";
    };
  };
};
```

Drop entirely:

- `services.adguardhome` block.
- `allowed_clients` machinery. Blocky has no source-IP allowlist by default — it
  serves whoever can reach the port. Source-IP enforcement is the firewall's job,
  and `networking.firewall.allowedUDPPorts/allowedTCPPorts = [53]` already opens
  the port to the brMGMT bridge only (no other interfaces reach phantasma).

Keep unchanged:

- `services.unbound` — including all `local-zone`, `local-data`, and `access-control`
  settings.
- `networking.firewall.allowedUDPPorts = [53]`, `allowedTCPPorts = [53]`.
- `services.resolved.enable = false` (port-53 conflict still applies).
- `networking.nameservers = ["127.0.0.1"]`.

## Tests

### Pure-eval test: `tests/lib/blocky-config.nix`

Asserts on the materialized `services.blocky.settings` (and the rendered YAML if
useful). Cheap, runs as part of `./scripts/run-checks.sh`.

Cases:

- Blocky binds `0.0.0.0:53` (the failure mode we just hit).
- Upstream is `127.0.0.1:5335`.
- Prometheus enabled.
- At least one denylist source declared.
- `enableConfigCheck = true` is the default — module build itself fails if YAML is
  malformed, so no extra assertion needed.

### NixOS integration test: `tests/modules/phantasma-dns.nix`

Two-VM test, same shape as `tests/modules/router6-dns-interception.nix`:

- `dns-server` — runs the phantasma DNS modules (Blocky + Unbound) on a single
  VLAN, simulated upstream.
- `client` — on the same VLAN, queries `dig @<dns-server-ip>`.

What it verifies:

1. **Reachability.** `dig @<dns-server-ip> example.com` returns an answer (not a
   timeout). This is the test the AdGuard stack would have caught the current bug
   with — and the test the user no longer has to run manually.
2. **Internal split-horizon.** `dig @<dns-server-ip> thebeyond.internal` resolves
   to the address declared in the network registry, served by Unbound's local-zone.
3. **Upstream forwarding.** `dig @<dns-server-ip> example.com` produces a query
   the simulated upstream sees (verified by running a tiny stub DNS server or by
   pointing at a controlled `unbound` instance with a known A record).
4. **Metrics endpoint.** `curl http://127.0.0.1:4000/metrics` on the DNS server
   returns 200 with `blocky_*` series present.

Stub upstream: simplest path is a second `services.unbound` in the test VM with a
forced static answer for a chosen domain (e.g. `test.local. IN A 192.0.2.99`).

Register the test in `flake.nix` checks. The test runs locally via
`nix build .#checks.x86_64-linux.phantasma-dns` — no SSH to phantasma needed.

## Risk and rollback

Risks:

- Blocky denylist sources may differ from AdGuard's defaults; expect a brief
  period where filtering is weaker until the deny-list set is curated.
- `DynamicUser = true` plus `StateDirectory = "blocky"` means state lives at
  `/var/lib/blocky` (not `/var/lib/private/AdGuardHome`). Need to add this path to
  phantasma's `environment.persistence."/persist".directories` — otherwise it's
  recreated empty on every boot. Empty state is *fine* for Blocky (denylists
  re-downloaded on start) but log history is lost across reboots.

Rollback:

- Single commit. Revert restores AdGuard config; persist volume still has the
  old `AdGuardHome` directory intact.

## Sequence

1. Write `tests/lib/blocky-config.nix` and `tests/modules/phantasma-dns.nix` against
   a config that doesn't exist yet. Both should fail.
2. Edit `hosts/thebeyond/microvm/guests/phantasma/modules/dns.nix` — swap AdGuard
   for Blocky.
3. Register tests in `flake.nix`.
4. Run `./scripts/run-checks.sh blocky-config phantasma-dns` — both green.
5. Deploy phantasma. Verify `dig @10.91.10.10 google.com` from thebeyond.

## Out-of-scope follow-ups (log only, don't do here)

- Blocky's REST API for the household kill-switch (per `self-hosting-recommendations.md` §8).
- Per-client groups.
- Wiring Blocky's `/metrics` into the Perses dashboards.
- Cleaning up the orphaned `/var/lib/private/AdGuardHome` directory in phantasma's
  persist volume.
- **Fix kresd's broken trust-anchor state so DNSSEC can be turned back on at
  the router.** Observed 2026-05-13: thebeyond's kresd logs
  `[timesk] cannot resolve '.' NS` and `[taupd] active refresh failed for
  . with rcode: 2` shortly after start. From then on, every forwarded query
  takes ~3s and returns SERVFAIL (the validator can't validate against an
  empty/missing root trust anchor). `systemctl restart kresd@1` does NOT
  fix it — the trust-anchor state is persistent (not a boot-time race
  against phantasma reachability, as initially diagnosed). The restart
  re-reads the same broken state.

  Workaround in place: `router6.dns.enableDNSSEC = false` on thebeyond,
  which renders `trust_anchors.set_insecure({ '.' })` and skips kresd-side
  validation entirely. Validation still happens upstream at phantasma's
  Unbound, which preserves the main DNSSEC threat model (public-internet
  hop). Only intra-LAN MITM detection is lost.

  To re-enable, first diagnose why kresd's root anchor isn't bootstrapping.
  Run on thebeyond with the workaround temporarily reverted
  (`enableDNSSEC = true`) so we can see the failing state:

  ```bash
  # 1. Where does kresd keep its trust-anchor state? DynamicUser hides it
  #    under /var/lib/private. Look at both and check size + contents.
  ls -la /var/lib/knot-resolver/ /var/lib/private/knot-resolver/ 2>/dev/null
  cat /var/lib/knot-resolver/root.keys 2>/dev/null
  cat /var/lib/private/knot-resolver/root.keys 2>/dev/null

  # 2. Does the nixpkgs knot-resolver package ship an initial root.keys?
  #    If it does, we should be copying it on first start. If not, we need
  #    to seed it ourselves.
  find /nix/store -maxdepth 4 -name 'root.keys' -path '*knot-resolver*' 2>/dev/null
  find /nix/store -maxdepth 4 -name 'root.hints' -path '*knot-resolver*' 2>/dev/null

  # 3. Confirm phantasma actually returns a valid signed DNSKEY for `.`.
  #    +dnssec asks for RRSIG; AD flag in the response = phantasma validated.
  dig @10.91.10.10 . DNSKEY +dnssec +multiline | head -40
  dig @10.91.10.10 . DNSKEY +dnssec +short

  # 4. Watch kresd's own diagnostic logs during a fresh restart. The
  #    [taupd] / [timesk] / [validt] tags identify trust-anchor flow.
  journalctl -u kresd@1 --since "5 minutes ago" --no-pager | \
    grep -E '\[(taupd|timesk|validt|valdat|cache)\]'

  # 5. Sanity check kresd's notion of root time-anchor age. If knot-resolver
  #    has a CLI/control socket, query its `cache.stats` and trust-anchor
  #    age. (kresd's control socket is at /run/knot-resolver/control@1.)
  echo 'trust_anchors.summary()' | \
    socat - UNIX-CONNECT:/run/knot-resolver/control@1 2>/dev/null || echo "no control socket"
  ```

  Interpretation:
  - `root.keys` empty/missing → cold-start has no anchor. Fix: ship one.
  - `root.keys` populated but kresd still SERVFAILs → likely a clock-skew
    or DS-mismatch issue. Check `timedatectl` and compare anchor against
    current IANA KSK.
  - phantasma `+dnssec` answer has no AD flag → upstream isn't signing,
    which would break validation regardless of kresd's state.

  Then pick the right fix:
  1. Seed kresd's `root.keys` at activation time from a known-good source
     (IANA-published KSK), so cold-start always has a valid initial anchor.
  2. Switch the kresd ↔ phantasma hop to DoT, which authenticates phantasma
     and lets us drop kresd's DNSSEC entirely without any security loss.
