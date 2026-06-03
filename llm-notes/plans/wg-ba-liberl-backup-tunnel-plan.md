# wg-ba: liberl offsite backup tunnel (per-host, tunnel-scoped egress)

Status: NOT STARTED — drafted, no code merged.

## Goal

Give **liberl** (NAS) a WireGuard tunnel to the offsite `remote` box so it can
push backups over SSH (borg), terminating the tunnel **on liberl itself** (not
the router). The tunnel is a `wg-quick` interface whose `.conf` is rendered by a
sops-nix template, so the sensitive remote endpoint never lands in the nix store.
Egress **over the tunnel** is firewalled to only the backup host:port; liberl's
other egress is left untouched for now (full host lockdown deferred — see Future).

Trust + posture:
- **liberl → remote only.** The remote must **not** initiate back into liberl.
  (Already true — liberl's source-restricted input firewall blocks it; see below.)
- **Limited tunnel egress.** Over `wg-ba`, liberl may reach *only* `192.168.0.35`
  on SSH (`tcp/22`); all other over-tunnel egress is dropped.

### Remote addressing (external — not our registry)

The remote is an **external box with its own networks**, so none of this lives in
the `network.nix` registry:

| thing                     | address          | notes                                  |
|---------------------------|------------------|----------------------------------------|
| remote wg peer            | `192.168.127.1`  | the peer's tunnel address              |
| backup host (SSH target)  | `192.168.0.35`   | **behind** the peer, on the remote LAN |
| liberl wg interface addr  | `192.168.127.x`  | **TBD — you provide** (peer is `.1`)   |

IPv4-only (no v6 given for the remote). It's the **same physical box** as the
existing thebeyond/trista wg-ba peer, but liberl uses the box's native
addressing; the `10.100.0.3` figure in thebeyond's config is stale for this
remote (trista's concern, re-tooled in the k3s plans — out of scope here).

### Scope: liberl only (with documented futures)

This plan is liberl-only on the tunnel itself. The existing thebeyond-side
`wg-ba` (the stale router-terminated trista path) is **removed up front in
Phase 0** — `remote → trista` SSH is confirmed unused. liberl's tunnel is fully
independent (its own keypair, the remote's native addressing); trista gets a
fresh direct tunnel later (Future #3).

Three things are explicitly **deferred and documented** (see "Future"):
1. **Full host egress lockdown on liberl** — easier after the **MACVLAN rework of
   the VM hosts**, which is also when liberl's *ingress* tightens to NFS+SMB only.
2. **Move liberl's tunnel to a gateway, likely bt8gw** (liberl's real gateway).
3. **Give trista its own direct tunnel**, replacing the interim router path.

## Why per-host now, not the router (decision record)

- The router6 "dynamic layer" we'd otherwise build only exists to get secret
  config materialized at runtime — which a **sops-nix template** already does.
- liberl is on **VLAN 11 (management), gateway = bt8gw**. Router termination on
  *thebeyond* would force liberl→remote across the transit /30 with a scoped
  forward rule + bt8gw route/fw4. Per-host deletes that. (If we later move to a
  gateway, bt8gw — liberl's *real* gateway — is the right one; see Future #2.)
- Blast radius: backups don't depend on thebeyond / the transit link, and a key
  compromise is contained to liberl.

Dial direction (confirmed): **liberl dials the remote; remote is DDNS.** liberl
holds the remote's dynamic endpoint (from sops) and needs endpoint
re-resolution (wg-quick only resolves at `up`).

## Direction + egress enforcement

**Inbound (remote → liberl): already blocked, no new rule required.** liberl's
input firewall (`hosts/liberl/default.nix:197`, `nas.nix:28`) is
source-restricted: SSH only from `{bt8gw, vHOME}` with a `tcp dport 22 drop`
catch-all; NFS/SMB/WSDD pinned to specific hosts/subnets. The remote
(`192.168.0.35` / `192.168.127.1`) matches none, so its inbound falls through to
the default drop.
- *Optional future-proofing* (recommended, cheap): an explicit `iifname "wg-ba"`
  input drop so a future globally-opened port can never be exposed over the tunnel.

**Egress over the tunnel: scoped, leaving the rest of liberl untouched.** A
targeted nftables output chain with `policy accept` constraining **only**
`oifname "wg-ba"` (lower-risk; full default-drop host lockdown waits for the
MACVLAN rework). IPv4-only:

```nix
networking.nftables.enable = true;
networking.nftables.tables.wg-ba = {
  family = "inet";
  content = ''
    chain output {
      type filter hook output priority 0; policy accept;
      oifname "wg-ba" ct state established,related accept
      oifname "wg-ba" ip daddr 192.168.0.35 tcp dport 22 accept
      oifname "wg-ba" drop
    }
    # optional input guard (see above)
    chain input {
      type filter hook input priority 0; policy accept;
      iifname "wg-ba" ct state established,related accept
      iifname "wg-ba" drop
    }
  '';
};
```

Two layers of "limited egress over the wireguard connection":
1. **Destination** is pinned by wg `AllowedIPs` (only `192.168.127.1/32` +
   `192.168.0.35/32` route over the tunnel).
2. **Service** is pinned to `192.168.0.35:22` by the output rule — note the peer
   itself (`192.168.127.1`) routes but gets **no** egress allow, exactly the
   "only the address I need" restriction.

Coexists with `networking.firewall` (same pattern as the calvard guests'
`networking.nftables.tables.egress`); `policy accept` means only wg-ba traffic is
filtered.

## Backup protocol

**SSH + borg** (borg transports over SSH). Only **SSH `tcp/22`** is needed, so the
over-tunnel rule pins dport 22 to `192.168.0.35`. Adjustable over time. Because we
are *not* doing the WAN underlay pinhole now, no nft rule references the remote's
DDNS endpoint, so the endpoint host **and** port both stay fully in sops.

## Secrets + wg-quick conf (liberl)

New wg keypair for liberl (pubkey → remote operator; privkey → liberl sops).
Sensitive value: the **remote endpoint** (`host:port`, DDNS — fully in sops).

sops template renders the wg-quick `.conf`:

```
[Interface]
PrivateKey = <sops placeholder: wg-ba-privatekey>
Address    = 192.168.127.x/32        # liberl's tunnel addr — YOU PROVIDE

[Peer]
PublicKey  = <remote pubkey — YOU PROVIDE (same O+WW… or new?)>
Endpoint   = <sops placeholder: wg-ba-endpoint>   # remote DDNS host:port
AllowedIPs = 192.168.127.1/32, 192.168.0.35/32
PersistentKeepalive = 25
```

Wire with `networking.wg-quick.interfaces.wg-ba.configFile =
config.sops.templates."wg-ba.conf".path;` (configFile mode — whole tunnel from
the rendered file, nothing in the store).

### Endpoint re-resolution (DDNS)

`wg-quick` resolves `Endpoint` once at `up`; a DDNS change kills the tunnel until
re-resolution. Add a systemd service+timer that re-reads the endpoint hostname and
runs `wg set wg-ba peer <remote-pubkey> endpoint <resolved>` when the handshake is
stale (`pkgs.wireguard-tools` ships a `contrib/reresolve-dns` script). Cadence
~2–5 min, `OnBootSec` + `OnUnitActiveSec`.

---

## Phases

> liberl's tunnel needs no registry change (external addressing). Phase 0 is an
> independent router-side cleanup; Phases 1–4 are liberl's tunnel.

### Phase 0 — Remove thebeyond's stale wg-ba (router-side cleanup) — NOT STARTED

Independent of liberl's tunnel; do as its own commit. `remote → trista` SSH is
confirmed unused, and the config is wired to the stale `10.100.0.3` addressing.
In `hosts/thebeyond/router.nix`:
- Delete the `ba-tunnel` zone (`:316`–`:327`).
- Drop `"ba-tunnel"` from `transit.accessTo` (`:390`) → `["external"]`.
- Delete the `wg-ba` topology entry (`:686`–`:709`).
- Delete the wg-ba→trista DNAT port-forward (`:623`–`:637`).
- Clean the two stale comments (`:251`, `:385`).

`hosts/thebeyond/sops.nix`: remove the `wg-ba-privatekey` secret (and its entry in
`secrets/secrets.yaml` — user re-encrypts).
`lib/common/data/network.nix`: remove the now-orphaned `wg-ba` block from
`rawWgNetworks` (`:304`) — confirm no remaining `wg."wg-ba"` consumers first.
Run `./scripts/run-checks.sh` (router6 + registry checks). No test fixtures
reference ba-tunnel/wg-ba, so this is contained.

### Phase 1 — liberl tunnel — NOT STARTED

- `hosts/liberl/secrets/secrets.yaml`: add `wg-ba-privatekey`, `wg-ba-endpoint`.
- `hosts/liberl/sops.nix`: declare secrets + `sops.templates."wg-ba.conf"` (with
  liberl's tunnel address, remote pubkey, AllowedIPs as above).
- New `hosts/liberl/wg-ba.nix` (imported from `default.nix`):
  `wg-quick.interfaces.wg-ba.configFile = …templates."wg-ba.conf".path;` + the
  reresolve-dns service+timer. Self-contained for cheap future removal.

### Phase 2 — Tunnel-scoped egress filter — NOT STARTED

- Add the `networking.nftables.tables.wg-ba` output chain limiting `oifname
  "wg-ba"` egress to `192.168.0.35:22`. Optionally add the `wg-ba` input drop.
- `policy accept` → liberl's non-tunnel egress is untouched (no NAS-breakage
  risk). Full default-drop host lockdown is Future #1.

### Phase 3 — Remote peer (off-repo, EXTERNAL) — NOT STARTED

On the offsite box: add a `liberl` peer (liberl's new pubkey, AllowedIPs =
liberl's tunnel addr `/32`); ensure it **listens** and the `wg-ba-endpoint` DDNS
name resolves to it; SSH/borg target reachable at `192.168.0.35`. Existing
`thebeyond` peer untouched.

### Phase 4 — Validation — NOT STARTED

- `nix build .#nixosConfigurations.liberl…`.
- Live: `wg show wg-ba` shows a recent handshake; borg-over-SSH to `192.168.0.35`
  works.
- `remote → liberl` NEW conn refused; liberl→`192.168.127.1` (any port) and
  liberl→`192.168.0.35` non-22 dropped; liberl's NFS/SMB/monitoring/deploy egress
  unaffected.
- DDNS flap: rotate the remote endpoint, confirm the reresolve timer recovers the
  tunnel within its cadence.

## Future

### Future #1 — Full host egress lockdown (after the VM-host MACVLAN rework)

Today we only filter the tunnel. The MACVLAN rework is what makes a strict
whole-host posture tractable: liberl's **ingress** tightens to **NFS + SMB only**,
and its **egress** moves to a default-drop allowlist (the repo's `mkEgressFilter`)
— DNS, NTP, fluent-bit→tharbad, internal attic (`zeiss`) substituter, plus the
over-tunnel rule, which folds in. (Doing it now means enumerating a live NAS's
egress with breakage risk — hence deferred.)

### Future #2 — Move liberl's tunnel to a gateway (likely bt8gw)

To stop liberl touching the WAN at all, move termination to **bt8gw** — liberl's
*actual* default gateway (preferable to thebeyond): single hop (no transit
crossing), bt8gw is already the management-zone egress enforcer, liberl needs zero
wg config, and OpenWRT brings native WireGuard + netifd DDNS re-resolution + a
build-time secrets path. Contingencies: bt8gw under declarative management (not
yet — dual-gateway in-flight); confirm BT8 WG throughput is a non-issue (likely —
offsite backup is WAN-upload-bound). Contained because liberl's tunnel is isolated
in `hosts/liberl/wg-ba.nix`.

### Future #3 — Direct tunnel to trista (when the server is ready)

When the k3s re-tooling stands trista up, give it its own direct per-host tunnel
(same pattern as liberl). The thebeyond-side `ba-tunnel`/`wg-ba` it would have
replaced is already gone (Phase 0). End state: liberl and trista each own a direct
tunnel; the router holds no wg-ba.

## Open items / inputs needed

- **liberl's tunnel address** (`192.168.127.x` + prefix) — you provide.
- **Remote pubkey** for liberl's peer — same `O+WW…` or a new one? — you provide.
- **Key generation**: user generates liberl's wg keypair; privkey → liberl sops,
  pubkey → remote. (Per workflow, the user runs the secret/decrypt commands.)
- **reresolve cadence** (default ~5 min unless the remote flaps often).
- **Optional `wg-ba` input drop**: include the belt-and-suspenders input guard, or
  rely on the existing source-restricted input firewall (already sufficient).
