# arseille: LuCI runbook — migrate mgmt plane from VLAN 10 to VLAN 12 (netmgmt)

**Status:** operator-facing runbook for reclassifying `arseille`
(NETGEAR GS108T v3, OpenWrt `realtek/rtl838x`) from the `network` /
VLAN 10 management plane (thebeyond-L3) to the `netmgmt` / VLAN 12
management plane (BT8-gateway-L3). arseille is the **first and only**
consumer of `netmgmt`; the zone has been a placeholder since the
dual-gateway plan landed.

The runbook performs the move with a **dual-stack window**: arseille
keeps its existing `10.91.10.12/24` interface for fallback while the
new `10.97.12.12/24` interface comes up alongside it. Retirement of
the VLAN 10 mgmt IP is a separate later step.

**Companion runbooks:**
[`bt8-bridge-luci-runbook.md`](bt8-bridge-luci-runbook.md),
[`bt8-gateway-luci-runbook.md`](bt8-gateway-luci-runbook.md).

**Companion config:** [`hosts/openwrt/arseille.nix`](../../hosts/openwrt/arseille.nix)
(current spec — `vlanId = 10`). The flake reflects the **pre-runbook**
state. The LuCI changes here are not back-ported to the flake during
this window; that's a follow-up (see end of doc).

**Why this runbook exists:** the current placement hairpins all
cross-VLAN admin traffic to arseille via thebeyond (VLAN 20/21 →
BT8-gw → transit → thebeyond → mesh → BT8-gw → arseille — the
counterexample called out at `dual-gateway-app-vlan-plan.md:217-220`).
arseille sits physically behind BT8-gateway, so terminating its L3 on
BT8-gw cuts the hairpin. The cost is back-porting the LuCI changes to
the flake later, plus an eventual fw4 rule on BT8-gw for cross-VLAN
admin access (deferred — the operator has explicitly accepted "not
routable from VLAN 20/21 until after the switch is in place").

**No thebeyond change:** unlike previous mgmt-access work, this
runbook does **not** touch `transit.forwardRules.network`. The new
mgmt plane is entirely BT8-gw-local; thebeyond never sees the new
traffic.

---

## Pre-flight checklist

- [ ] **Current mgmt path to arseille works:** `ssh root@10.91.10.12`
      succeeds from a host on `network`/10 (or wherever your current
      management plane reaches from).
- [ ] **Root SSH + LuCI access to BT8-gateway** — Phase 1 happens
      there. Confirm now; this runbook fails halfway if BT8-gw isn't
      reachable.
- [ ] **sysupgrade backups of BOTH devices:**

      ```sh
      ssh root@10.91.10.12   'sysupgrade -b /tmp/arseille-pre.tar.gz'
      ssh root@10.255.255.2  'sysupgrade -b /tmp/bt8gw-pre.tar.gz'
      scp root@10.91.10.12:/tmp/arseille-pre.tar.gz   ~/
      scp root@10.255.255.2:/tmp/bt8gw-pre.tar.gz     ~/
      ```

      Name them `arseille-2026-MM-DD-pre.tar.gz` and
      `bt8gw-2026-MM-DD-pre.tar.gz` in the operator secret store.

- [ ] **USB-serial cable + console pinouts** for **both** the GS108T
      and BT8-gateway as recovery channel.
- [ ] **Second SSH session open** to arseille (for runtime checks like
      `bridge vlan show` while making LuCI changes in the browser).
- [ ] **Wired path from BT8-gw to arseille is known and stable** —
      confirm which BT8-gw port the arseille trunk lands on. The
      runbook calls this `<BT8GW_TRUNK>`.

---

## Network context

### Before (current)

```
operator (any VLAN)
        │
        ▼
{ BT8-gw → transit → thebeyond }   (L3 chain for cross-VLAN)
                                 │
                                 ▼
                          brMGMT (VLAN 10)
                                 │
                                 ▼
                          batman mesh fabric
                                 │
                                 ▼
                          arseille (10.91.10.12 on br-lan.10)
```

### After (target end-state, post-cleanup)

```
operator (any VLAN)
        │
        ▼
BT8-gw  (L3 for VLAN 12 / netmgmt)
        │ direct: VLAN 12 trunk
        ▼
arseille (10.97.12.12 on br-lan.12)
```

### During the runbook (dual-stack, both work)

```
                arseille
              ┌────────────────────┐
              │ br-lan.10  → 10.91.10.12 (old, kept for fallback)
              │ br-lan.12  → 10.97.12.12 (new, primary going forward)
              └────────────────────┘
```

### Addressing table

| What        | Old (VLAN 10)              | New (VLAN 12)                   |
| ----------- | -------------------------- | ------------------------------- |
| Subnet      | `10.91.10.0/24`            | `10.97.12.0/24`                 |
| ULA         | `fdc6:55f2:0a5e:000a::/64` | `fdc6:55f2:0a5e:100c::/64`      |
| arseille IP | `10.91.10.12/24`           | `10.97.12.12/24`                |
| Gateway     | `10.91.10.1` (thebeyond)   | `10.97.12.1` (BT8-gw)           |
| DNS         | `10.91.10.10` (phantasma)  | `10.97.12.1` (BT8-gw forwarder) |
| L3 owner    | thebeyond                  | BT8-gateway                     |
| Zone        | `network`                  | `netmgmt`                       |

`hostId` stays `12` in both; arseille just lands on the
group-1-prefix version of its host slot.

---

## Phase 1 — BT8-gateway prep

Operator on BT8-gateway. Either via SSH/UCI or LuCI — both work; the
runbook gives UCI commands because they're more compact for review.
These take roughly five minutes; do them just before Phase 2.

### 1.A — Add VLAN 12 to the L2 bridge

Identify the bridge that carries the trunk to arseille and the trunk
port name (`<BT8GW_TRUNK>`). On the typical config that's `br-lan`
and a `lan*` port. Verify with `bridge vlan show`.

Add VLAN 12 to the bridge VLAN filtering table, tagged on
`<BT8GW_TRUNK>`. The exact UCI shape depends on whether BT8-gw uses
the named-bridge layout or the older `config switch_vlan` style. For
modern DSA:

```sh
uci add network bridge-vlan
uci set network.@bridge-vlan[-1].device='br-lan'
uci set network.@bridge-vlan[-1].vlan='12'
uci add_list network.@bridge-vlan[-1].ports='<BT8GW_TRUNK>:t'
uci commit network
```

Don't reload yet — batch with 1.B + 1.C.

### 1.B — Add the L3 interface for VLAN 12

```sh
uci set network.netmgmt=interface
uci set network.netmgmt.device='br-lan.12'
uci set network.netmgmt.proto='static'
uci set network.netmgmt.ipaddr='10.97.12.1'
uci set network.netmgmt.netmask='255.255.255.0'
uci set network.netmgmt.ip6addr='fdc6:55f2:0a5e:100c::1/64'
uci commit network
```

### 1.C — Add the fw4 zone

Minimum viable: zone covers the new interface, permits input (so
admin can reach BT8-gw's own SSH/LuCI from netmgmt), permits forward
out to `wan` (so arseille can reach internet for package updates if
needed). No inbound forward from other zones yet — that's the
"deferred until after the switch" piece.

```sh
uci add firewall zone
uci set firewall.@zone[-1].name='netmgmt'
uci set firewall.@zone[-1].network='netmgmt'
uci set firewall.@zone[-1].input='ACCEPT'
uci set firewall.@zone[-1].output='ACCEPT'
uci set firewall.@zone[-1].forward='REJECT'

uci add firewall forwarding
uci set firewall.@forwarding[-1].src='netmgmt'
uci set firewall.@forwarding[-1].dest='wan'

uci commit firewall
```

(Adjust `wan` to whatever BT8-gw's WAN-equivalent zone is named —
likely `wan` or the transit-side egress zone, depending on how the
gateway is wired.)

### 1.D — Apply and verify on BT8-gw

```sh
/etc/init.d/network reload
/etc/init.d/firewall reload
ip -br addr show br-lan.12          # expect 10.97.12.1/24 + ULA
bridge vlan show dev <BT8GW_TRUNK>  # expect "12 Egress Untagged" absent,
                                    # "12" tagged present
ping -c 1 10.97.12.1                # local interface
```

`netmgmt` is now a live L3 plane with no consumer yet. Phase 2 adds
arseille as the first consumer.

> **Skip DHCP/DNS on netmgmt.** arseille is the only consumer and
> will be statically configured. odhcpd/dnsmasq for VLAN 12 is
> follow-up work, not a gate on this runbook.

---

## Phase 2 — arseille LuCI

SSH into arseille from the operator's current path:

```sh
ssh root@10.91.10.12
```

Dump current state for reference:

```sh
uci show network
ip -br link
bridge vlan show
```

Keep the dump open in a scratch window.

### 2.A — Add VLAN 12 to the bridge VLAN filtering table

**Network → Interfaces → Devices** tab.

Find `br-lan` and click **Configure…** → **Bridge VLAN filtering**
tab. The existing table should already have VLAN 10 with the trunk
ports set to `t` (tagged).

Add a new row:

- **VLAN ID**: `12`
- **Local**: checked (so the bridge terminates VLAN 12 locally — this
  is what makes `br-lan.12` exist as a device)
- For each trunk port (`lan1`–`lan4` per `defaultSwitchTrunkPorts`):
  set to **t** (tagged).

**Save**, then **Save & Apply.**

> **Risk** — adding a row is additive and doesn't disturb VLAN 10's
> existing config. The existing `br-lan.10` mgmt interface stays up.
> If LuCI's apply somehow drops the session anyway, the rollback
> timer will revert.

Verify in the second SSH session:

```sh
bridge vlan show
# expect: VLAN 10 and VLAN 12 both listed on each trunk port,
# both tagged, both with "PVID Egress Untagged" absent
```

### 2.B — Create the new management interface

**Network → Interfaces → Add new interface…**

- **Name**: `mgmt_new` (or whatever the operator prefers — keep it
  visually distinct from the existing `lan` / `mgmt` interface so
  there's no confusion mid-runbook).
- **Protocol**: `Static address`
- **Device**: `br-lan.12` (should auto-appear in the dropdown after
  2.A's Save & Apply created the VLAN device).

Click **Create interface**. Then on the new interface's edit page:

- **General Settings** tab:
  - **IPv4 address**: `10.97.12.12`
  - **IPv4 netmask**: `255.255.255.0`
  - **IPv4 gateway**: `10.97.12.1`
  - **IPv6 address**: `fdc6:55f2:0a5e:100c::12/64`
  - **IPv6 gateway**: `fdc6:55f2:0a5e:100c::1`
  - **Use custom DNS servers**: `10.97.12.1`
    (or `10.91.10.10` / phantasma if you prefer the upstream resolver
    directly — both will work; BT8-gw's dnsmasq forwards `.internal`
    queries to `10.255.255.1` and recurses everything else)
- **Advanced Settings** tab:
  - **Use default gateway**: **unchecked** (important — see callout
    below)
  - **Use DNS servers advertised by peer**: unchecked

**Save**, then **Save & Apply** at the bottom of the Interfaces page.

> **Why "Use default gateway = unchecked"** — leaving it checked
> would install a _second_ default route via `10.97.12.1`,
> competing with the existing default via `10.91.10.1`. With both
> default routes equal-cost, Linux will load-balance and outbound
> traffic from arseille will half-blackhole during the dual-stack
> window. The mgmt interfaces only need to reach their own subnets
> (the bridges) plus respond to inbound; they don't need to be the
> egress path for arseille's own outbound. Leave VLAN 10's default
> as the sole default route until cleanup.

Verify:

```sh
ip -br addr show
# expect both inet lines present:
#   br-lan.10  ...  10.91.10.12/24
#   br-lan.12  ...  10.97.12.12/24

ip route
# expect ONE default route, via 10.91.10.1 dev br-lan.10

ip -6 addr show br-lan.12 | grep inet6
# expect fdc6:55f2:0a5e:100c::12/64 (plus link-local)
```

### 2.C — Leave the existing VLAN 10 mgmt interface alone

**Critical:** do **not** touch the existing `lan` / `mgmt` interface
on `br-lan.10`. It's the fallback for the rest of the runbook and
for any service that currently knows about `10.91.10.12`.

If the audit dump showed the existing interface using `br-lan` as
the device (not `br-lan.10`), and 2.A's bridge VLAN filtering
introduced VLAN 10 to the filtering table with **Local: checked**,
then the interface should already be effectively on `br-lan.10` —
no edit needed. If LuCI shows it bound to bare `br-lan`, **leave it
that way**; it'll continue to receive untagged frames where the
bridge isn't VLAN-aware, and tagged VLAN-10 frames via the new VLAN
device. The two coexist.

### 2.D — Confirm SSH and LuCI bind to both addresses

OpenWrt's default `dropbear` and `uhttpd` listen on all interfaces
(`0.0.0.0` / `[::]`), so both new and old IPs are reachable without
config changes. Confirm in SSH:

```sh
ss -tlnp 'sport = :22'    # 0.0.0.0:22 + [::]:22
ss -tlnp 'sport = :80'    # 0.0.0.0:80 + [::]:80
ss -tlnp 'sport = :443'   # 0.0.0.0:443 + [::]:443
```

If any are bound to a specific IP (e.g., `10.91.10.12:22`), widen to
`0.0.0.0` per Phase 2.D of the previous runbook draft. Same shape;
see [bt8-bridge-luci-runbook §3.F](bt8-bridge-luci-runbook.md) for
the LuCI path.

### 2.E — Firewall posture

Per arseille's role (L2 switch, no L3 forwarding), the local firewall
should stay disabled:

```sh
/etc/init.d/firewall status
```

If active, disable per the previous runbook draft's §2.E. If already
disabled, no-op.

---

## Phase 3 — Verification

### From BT8-gateway (the new primary mgmt path)

```sh
ping -c 2 10.97.12.12              # arseille's new IP via VLAN 12
ssh root@10.97.12.12 'echo OK'     # SSH lands on new IP
curl -fsI http://10.97.12.12/      # LuCI HTTP responds
curl -fskI https://10.97.12.12/    # LuCI HTTPS responds (-k: self-signed)
```

All four should succeed. If any fail:

- ARP check: `ip neigh show dev br-lan.12` on BT8-gw — expect arseille's
  MAC at 10.97.12.12. If missing, VLAN 12 isn't crossing the trunk →
  re-audit Phase 1.A and 2.A bridge VLAN tables.
- Frame check: `tcpdump -i br-lan.12 -nne icmp` on BT8-gw while
  pinging from another shell. Expect to see the echo request leave
  and the reply arrive. If request leaves but no reply, arseille's
  side isn't responding → check 2.B interface state and 2.E firewall.

### From the operator's existing path (VLAN 10 fallback)

```sh
ssh root@10.91.10.12 'echo still works'
```

Should still work exactly as before. If broken, **immediately**
restore from `arseille-pre.tar.gz` — the dual-stack window's whole
point is preserving the old path during the transition. A broken
VLAN 10 path means 2.A or 2.B did something unexpected to the existing
bridge.

### On arseille itself

```sh
ip -br addr show           # both inet addresses present (10.91.10.12, 10.97.12.12)
ip route                   # SINGLE default via 10.91.10.1 — not two!
ip neigh show dev br-lan.12 | head  # at minimum 10.97.12.1 (BT8-gw)
bridge vlan show           # VLAN 10 and 12 both tagged on trunk ports
/etc/init.d/firewall status  # inactive
```

### Post-runbook backups

```sh
ssh root@10.91.10.12   'sysupgrade -b /tmp/arseille-post.tar.gz'
ssh root@10.255.255.2  'sysupgrade -b /tmp/bt8gw-post.tar.gz'
scp root@10.91.10.12:/tmp/arseille-post.tar.gz   ~/
scp root@10.255.255.2:/tmp/bt8gw-post.tar.gz     ~/
```

Both go in the operator secret store as `arseille-2026-MM-DD-post.tar.gz`
and `bt8gw-2026-MM-DD-post.tar.gz`.

---

## What's deferred (out of scope for this runbook)

### Cross-VLAN admin access to arseille on the new IP

VLAN 20 / 21 / 11 hosts currently **cannot** reach `10.97.12.12`.
BT8-gw's fw4 has no `trusted → netmgmt`, `lab → netmgmt`, or
`management → netmgmt` forward rule yet — the only consumer of
netmgmt is arseille and the only existing path is from BT8-gw itself.

The operator explicitly accepted this. When cross-VLAN admin from
20/21 is wanted, add to BT8-gw's `/etc/config/firewall`:

```sh
uci add firewall forwarding
uci set firewall.@forwarding[-1].src='trusted'
uci set firewall.@forwarding[-1].dest='netmgmt'
# repeat for src='lab' and src='management' as desired
# (or define a forwarding rule with a port allowlist instead of full forward)
uci commit firewall && /etc/init.d/firewall reload
```

This is a few-line BT8-gw fw4 change; no thebeyond involvement.

### Flake back-port

The repo state still reflects pre-runbook reality:

- `lib/common/data/network.nix`: `arseille = 12;` is under
  `network.hosts`, not `netmgmt.hosts`.
- `hosts/openwrt/arseille.nix`: `vlanId = 10;`.

Both need updating before the next image build of arseille would
match the new live state. Suggested sequence:

1. Move `arseille = 12;` from `network.hosts` to `netmgmt.hosts` in
   the registry. The hostId stays `12` — registry deriveation gives
   the new IP automatically (`10.97.12.12` from group-1 prefix +
   vlan 12 + host 12).
2. Update `hosts/openwrt/arseille.nix`: `vlanId = 12`. The
   `mkSwitchConfig` builder will generate matching UCI for the
   new mgmt VLAN.
3. **Before deploying the rebuilt image**, remove the VLAN 10 mgmt
   interface from the live device (see "Retiring the VLAN 10 mgmt
   interface" below) — otherwise the flake-driven UCI and the live
   UCI diverge in a confusing way.
4. Update any `.internal` / `mkExtraHosts` consumers that pinned
   `10.91.10.12` (grep for it; should only be the registry-generated
   hostsfile).
5. Drop the obsolete `# L2 switch (deferred reclassification)` comment
   on the old `network.hosts.arseille` entry (which is gone) and add
   a current note on the new `netmgmt.hosts.arseille` entry.

### Retiring the VLAN 10 mgmt interface

After ≥24h of stable BT8-gw-mediated mgmt access:

1. Confirm no service / monitoring / DNS record still pins
   `10.91.10.12` — grep the repo, check Prometheus targets, check
   `mkExtraHosts` output.
2. On arseille LuCI: **Network → Interfaces → Remove** on the old
   `lan` / `mgmt` interface (the one bound to `br-lan.10`).
3. Optionally remove VLAN 10 from arseille's bridge VLAN filtering
   table — but only if arseille doesn't need to pass VLAN 10 frames
   through (it almost certainly does, since other VLAN 10 hosts on
   the fabric reach each other via L2 broadcast that includes the
   switch — keep VLAN 10 in the filtering table, just unbind the L3
   interface).
4. Save & Apply, then take a `arseille-2026-MM-DD-vlan10-retired.tar.gz`
   backup.

---

## Appendix A — Configuration reference

Authoritative spec for what arseille's live configuration should look
like after this runbook. Sidecar reference for use while configuring
in LuCI or auditing via `uci show`. The flake's
`hosts/openwrt/arseille.nix` is **not** authoritative until the
back-port lands (see [arseille flake-not-authoritative memory](../../../.claude/projects/-home-mutantmell-git-dotfiles/memory/feedback_arseille_flake_not_authoritative.md));
this appendix is.

**Two states documented:**

- **§Transitional** — during the dual-stack window (VLAN 10 and VLAN
  12 mgmt interfaces both live). This is what the device should look
  like immediately after Phase 2 completes.
- **§Target** — after VLAN 10 mgmt interface retirement. Single
  management plane on VLAN 12.

The two states differ only in the presence of the VLAN 10 mgmt
interface plus its `bridge-vlan` entry's `local` flag. Everything
else is identical.

**Open variables** (operator decides, marked `OPERATOR:` inline):

- Which trunk port the BT8-gateway uplink lands on. Assume `lan1`
  unless otherwise; adjust if your physical layout differs.
- Which non-mgmt VLANs to carry through arseille's trunk. Default:
  all VLANs registered in `lib/common/data/network.nix` per the
  L2-fabric-passthrough principle from the BT8-bridge runbook
  ("every VLAN that crosses the homelab flows opaquely"). Prune if
  arseille has no endpoint devices on a given VLAN AND no upstream
  reason to pass it through.
- Access-port assignments for endpoint devices. Default: none — all
  lan ports trunk-tagged. Convert individual ports to untagged on a
  specific VLAN as endpoint devices land.
- DNS source on the mgmt interface. Default: `10.97.12.1`
  (BT8-gateway's dnsmasq). Alternative: `10.91.10.10` (phantasma
  direct).

### A.1 System

`uci show system`:

```
system.@system[0].hostname='arseille'
system.@system[0].timezone='UTC'
system.@system[0].zonename='UTC'
system.@system[0].log_size='64'    # default; tune if log volume is an issue
```

LuCI — **System → System → General Settings**:

| Field    | Value      |
| -------- | ---------- |
| Hostname | `arseille` |
| Timezone | `UTC`      |

### A.2 Network — bridge device

`uci show network` (bridge):

```
network.switch=device
network.switch.name='switch'
network.switch.type='bridge'
network.switch.ports='lan1 lan2 lan3 lan4 lan5 lan6 lan7 lan8'
```

LuCI — **Network → Interfaces → Devices**:

| Field          | Value                                          |
| -------------- | ---------------------------------------------- |
| Type           | Bridge                                         |
| Device name    | `switch` (or `br-lan` if that's what's there)  |
| Bridge ports   | `lan1`–`lan8` (all 8 ports)                    |
| MTU            | default                                        |
| VLAN filtering | **enabled** (checkbox on the bridge edit page) |

> The bridge name (`switch` vs `br-lan`) doesn't matter for
> correctness; use whichever the device currently has and don't
> rename mid-migration. The rest of this spec uses `switch`.

### A.3 Network — bridge VLAN filtering table

This is the trunk-vs-access plane. Each `bridge-vlan` entry declares
one VLAN ID, the per-port tagging (`t` tagged, untagged otherwise),
and whether the bridge itself terminates that VLAN (`local`).

#### §Target state

| VLAN | Name       | Trunk ports (tagged)            | Access ports (untagged) | Local on bridge |
| ---- | ---------- | ------------------------------- | ----------------------- | --------------- |
| 10   | network    | `lan1`–`lan8` (or trunk subset) | OPERATOR                | **no**          |
| 11   | management | `lan1`–`lan8`                   | OPERATOR                | no              |
| 12   | netmgmt    | `lan1`–`lan8`                   | OPERATOR                | **yes**         |
| 20   | trusted    | `lan1`–`lan8`                   | OPERATOR                | no              |
| 21   | lab        | `lan1`–`lan8`                   | OPERATOR                | no              |
| 30   | untrusted  | `lan1`–`lan8`                   | OPERATOR                | no              |
| 31   | adu        | `lan1`–`lan8`                   | OPERATOR                | no              |
| 40   | iot        | `lan1`–`lan8`                   | OPERATOR                | no              |
| 41   | game       | `lan1`–`lan8`                   | OPERATOR                | no              |
| 50   | app        | `lan1`–`lan8`                   | OPERATOR                | no              |
| 100  | dmz        | `lan1`–`lan8`                   | OPERATOR                | no              |

**Only VLAN 12 has `local='1'`** — that's what creates the
`switch.12` device the mgmt interface binds to. Every other VLAN is
L2-passthrough (frames cross the bridge between trunk-tagged ports
without local L3 termination).

#### §Transitional state (additional override)

| VLAN | Name    | Trunk ports (tagged) | Access ports | Local on bridge                                  |
| ---- | ------- | -------------------- | ------------ | ------------------------------------------------ |
| 10   | network | `lan1`–`lan8`        | OPERATOR     | **yes** (override; revert to `no` at retirement) |

In the transitional state, VLAN 10's row has `local='1'` (so
`switch.10` exists for the fallback mgmt interface). At retirement,
flip it back to `local='0'` — the row stays in the table because
VLAN 10 still needs to pass through arseille for other VLAN-10
endpoints on the fabric (thebeyond, phantasma, bt8bridge).

`uci show network` (bridge-vlan, one entry per VLAN):

```
network.@bridge-vlan[N]=bridge-vlan
network.@bridge-vlan[N].device='switch'
network.@bridge-vlan[N].vlan='12'
network.@bridge-vlan[N].ports='lan1:t lan2:t lan3:t lan4:t lan5:t lan6:t lan7:t lan8:t'
network.@bridge-vlan[N].local='1'
```

Same shape per VLAN; only `vlan` and `local` differ.

LuCI — **Network → Interfaces → Devices → switch → Configure →
Bridge VLAN filtering**:

Each row: VLAN ID, then per-port column shows `t` (tagged) / `u`
(untagged) / `*` (PVID untagged) / blank (not on this port). Local
checkbox to the right.

### A.4 Network — per-port MTU devices (optional)

The switch's underlying device entries can pin per-port MTU. For
arseille (no batman, no jumbo frames needed), defaults are fine —
skip this section if `uci show network` doesn't already have
`port_lanN` entries. If it does:

```
network.port_lan1=device
network.port_lan1.name='lan1'
network.port_lan1.mtu='1532'  # default headroom
```

…and similar for `lan2` through `lan8`. No LuCI configuration
needed — devices show up under Network → Interfaces → Devices.

### A.5 Network — loopback (default, untouched)

```
network.loopback=interface
network.loopback.device='lo'
network.loopback.proto='static'
network.loopback.ipaddr='127.0.0.1'
network.loopback.netmask='255.0.0.0'
```

### A.6 Network — management interface(s)

#### §Target state — single interface on VLAN 12

```
network.netmgmt=interface
network.netmgmt.device='switch.12'
network.netmgmt.proto='static'
network.netmgmt.ipaddr='10.97.12.12'
network.netmgmt.netmask='255.255.255.0'
network.netmgmt.ip6addr='fdc6:55f2:0a5e:100c::12/64'
network.netmgmt.gateway='10.97.12.1'
network.netmgmt.ip6gw='fdc6:55f2:0a5e:100c::1'
network.netmgmt.dns='10.97.12.1'   # OPERATOR: or '10.91.10.10' (phantasma direct)
network.netmgmt.defaultroute='1'
```

LuCI — **Network → Interfaces → edit `netmgmt`**:

| Tab               | Field                       | Value                        |
| ----------------- | --------------------------- | ---------------------------- |
| General Settings  | Protocol                    | Static address               |
| General Settings  | Device                      | `switch.12`                  |
| General Settings  | IPv4 address                | `10.97.12.12`                |
| General Settings  | IPv4 netmask                | `255.255.255.0`              |
| General Settings  | IPv4 gateway                | `10.97.12.1`                 |
| General Settings  | IPv6 address                | `fdc6:55f2:0a5e:100c::12/64` |
| General Settings  | IPv6 gateway                | `fdc6:55f2:0a5e:100c::1`     |
| General Settings  | Use custom DNS servers      | `10.97.12.1`                 |
| Advanced Settings | Use default gateway         | **checked**                  |
| Advanced Settings | Use DNS servers advertised… | unchecked                    |

#### §Transitional state — both interfaces

The target `netmgmt` interface above, **plus** the existing VLAN 10
interface (left in place from before the migration):

```
network.lan=interface
network.lan.device='switch.10'
network.lan.proto='static'
network.lan.ipaddr='10.91.10.12'
network.lan.netmask='255.255.255.0'
network.lan.gateway='10.91.10.1'
network.lan.dns='10.91.10.10'
network.lan.defaultroute='1'    # transitional: VLAN 10 keeps default route
```

And — critical — the `netmgmt` interface (the new one) must have
`defaultroute='0'` during the dual-stack window:

```
network.netmgmt.defaultroute='0'  # transitional ONLY; flip to '1' at retirement
```

LuCI: edit `netmgmt` → Advanced Settings → **uncheck** "Use default
gateway" during transition.

This avoids ECMP'ing across two default routes. VLAN 10's default
stays primary during transition; flip to VLAN 12 at retirement.

### A.7 Firewall

`/etc/init.d/firewall disable`. No zones, no rules. `uci show
firewall` returns empty (or whatever the default OpenWrt skeleton
ships with, all inert because the service isn't running).

LuCI — **Network → Firewall** shows "Firewall is disabled". If any
zones or rules are present, they're inert but should be removed for
hygiene.

> **Why disabled** — arseille is L2-only. Every policy decision
> happens upstream on BT8-gw (or, for VLAN 10-routed flows,
> thebeyond). A local firewall here is duplicate enforcement that
> adds nothing because the device only sees traffic that already
> passed the upstream check. Mirrors the BT8-bridge posture.

### A.8 DHCP / DNS

`/etc/init.d/dnsmasq disable` and `/etc/init.d/odhcpd disable`.
arseille serves neither DHCP nor DNS. `uci show dhcp` may have
default skeleton entries — they're inert.

LuCI — **Network → DHCP and DNS**, **Network → Interfaces → individual
interface → DHCP Server** tab: leave all DHCP-server-side settings
empty or "ignore interface".

### A.9 SSH (dropbear)

```
dropbear.@dropbear[0]=dropbear
dropbear.@dropbear[0].Port='22'
dropbear.@dropbear[0].PasswordAuth='off'        # OPERATOR: keep 'on' until keys verified
dropbear.@dropbear[0].RootPasswordAuth='off'    # OPERATOR: same
dropbear.@dropbear[0].Interface=''              # listen all (unset)
```

Authorized keys at `/etc/dropbear/authorized_keys` must include the
operator's `deploy` and `home` keys (whichever are in use). Cross-ref
`lib/common/data/openwrt.nix`'s `owrtData.authorizedKeys` for the
canonical list.

LuCI — **System → Administration → SSH Access**:

| Field             | Value                             |
| ----------------- | --------------------------------- |
| Interface         | unspecified (listen all)          |
| Port              | `22`                              |
| Password auth     | OPERATOR (off once keys verified) |
| Allow root login… | OPERATOR (off once keys verified) |
| Gateway ports     | off                               |

LuCI — **System → Administration → SSH-Keys**: paste operator keys.

### A.10 LuCI (uhttpd)

```
uhttpd.main=uhttpd
uhttpd.main.listen_http='0.0.0.0:80' '[::]:80'
uhttpd.main.listen_https='0.0.0.0:443' '[::]:443'
uhttpd.main.cert='/etc/uhttpd.crt'
uhttpd.main.key='/etc/uhttpd.key'
uhttpd.main.redirect_https='0'   # OPERATOR: '1' to force HTTPS
uhttpd.main.rfc1918_filter='0'   # required — cross-VLAN admin lands as
                                 # "external" sources from uhttpd's POV
```

`rfc1918_filter` must be **0** for cross-VLAN admin access — uhttpd
defaults to blocking RFC1918 sources arriving from "WAN-side" zones,
which trips when admin VLANs route in through the upstream forward
chain.

No dedicated LuCI page for uhttpd config; edit via SSH or **LuCI →
System → File Editor**.

### A.11 System services summary

| Service    | State           | Verify with                              |
| ---------- | --------------- | ---------------------------------------- |
| `network`  | enabled, active | `/etc/init.d/network enabled` returns 0  |
| `dropbear` | enabled, active | `/etc/init.d/dropbear enabled` returns 0 |
| `uhttpd`   | enabled, active | `/etc/init.d/uhttpd enabled` returns 0   |
| `firewall` | **disabled**    | `/etc/init.d/firewall enabled` returns 1 |
| `dnsmasq`  | **disabled**    | `/etc/init.d/dnsmasq enabled` returns 1  |
| `odhcpd`   | **disabled**    | `/etc/init.d/odhcpd enabled` returns 1   |
| `rpcd`     | enabled, active | (LuCI dependency)                        |

### A.12 Runtime state verification

Run these on arseille and compare to the expected output. Mismatch
on any line indicates a config drift.

#### IP addresses

```sh
ip -br addr show | grep -v 'DOWN\b'
```

§Target state — expected:

```
lo               UNKNOWN        127.0.0.1/8 ::1/128
switch           UP             <link-local>
switch.12        UP             10.97.12.12/24 fdc6:55f2:0a5e:100c::12/64 <link-local>
lan1..lan8       UP             <no L3>
```

§Transitional state — also expected:

```
switch.10        UP             10.91.10.12/24 <link-local>
```

#### Routing

§Target state:

```sh
ip -4 route
# expected:
# default via 10.97.12.1 dev switch.12 proto static
# 10.97.12.0/24 dev switch.12 proto kernel scope link src 10.97.12.12

ip -6 route | grep -v fe80
# expected default + connected for fdc6:55f2:0a5e:100c::/64
```

§Transitional state:

```sh
ip -4 route
# expected:
# default via 10.91.10.1 dev switch.10 proto static        ← single default
# 10.91.10.0/24 dev switch.10 proto kernel scope link src 10.91.10.12
# 10.97.12.0/24 dev switch.12 proto kernel scope link src 10.97.12.12
```

**Exactly one `default` route** in transitional state — two means
the `defaultroute='0'` on `netmgmt` was lost.

#### Bridge VLANs

```sh
bridge vlan show
```

Per port, expect each carried VLAN listed with the `Egress Untagged`
flag _absent_ (since we tagged everything). VLAN 12 should be
listed as `local` somewhere in the output.

#### Listening services

```sh
ss -tlnp 'sport = :22 or sport = :80 or sport = :443'
```

Expected: each port has at least an IPv4 (`0.0.0.0:`) listener,
ideally also an IPv6 (`[::]:` ) listener. Listening on a specific
IP instead of `0.0.0.0` means only one of the mgmt interfaces gets
the service.

#### Firewall

```sh
nft list ruleset | head
```

Expected: nothing of substance (the netfilter framework loads but
no fw4-emitted rules). `/etc/init.d/firewall status` should report
inactive.

#### Neighbors (after some traffic)

```sh
ip neigh show dev switch.12
```

Expected entries: at minimum BT8-gateway at `10.97.12.1` (REACHABLE
or STALE).

### A.13 Reachability matrix

After the runbook completes:

| From subnet     | VLAN | To `10.91.10.12` (transitional) | To `10.97.12.12` (target+transitional)  |
| --------------- | ---- | ------------------------------- | --------------------------------------- |
| `10.91.10.0/24` | 10   | direct (local)                  | indirect via BT8-gw (works)             |
| `10.97.12.0/24` | 12   | (only arseille is in this VLAN) | direct (local) — only BT8-gw is there   |
| `10.97.11.0/24` | 11   | via thebeyond (existing rule)   | **blocked** until BT8-gw fw4 rule added |
| `10.97.20.0/24` | 20   | via thebeyond (existing rule)   | **blocked** until BT8-gw fw4 rule added |
| `10.97.21.0/24` | 21   | via thebeyond (existing rule)   | **blocked** until BT8-gw fw4 rule added |
| other VLANs     | …    | blocked (by design)             | blocked (by design)                     |

The "blocked" cells are the deferred follow-up the operator
accepted — add `src=trusted/lab/management dest=netmgmt` fw4
forwards on BT8-gw when cross-VLAN admin is wanted (see
[What's deferred](#whats-deferred-out-of-scope-for-this-runbook)).

### A.14 Diff vs current state (cheat sheet)

To compare the live device against this spec in one go:

```sh
ssh root@10.91.10.12 'uci show network; uci show firewall; uci show dropbear; uci show uhttpd; uci show system; uci show dhcp' \
  > arseille-live.uci
# manually diff sections against this spec, or:
diff <(grep -E '^(network|firewall|dropbear|uhttpd)\.' arseille-live.uci | sort) <(your-spec-extract | sort)
```

There's no automated diff tool yet — the gap closes when the flake
back-port lands and `nix run .#openwrt-show-config -- arseille`
becomes authoritative.

### A.15 LuCI menu cheat-sheet

| Task                                | LuCI path                        |
| ----------------------------------- | -------------------------------- |
| Bridge VLAN filtering / trunk ports | Network → Interfaces → Devices   |
| Mgmt interface IP                   | Network → Interfaces             |
| SSH listener / keys                 | System → Administration          |
| Firewall (verify off)               | Network → Firewall               |
| Backup config                       | System → Backup / Flash Firmware |

---

## Appendix B — Troubleshooting

### Symptom: `ssh root@10.97.12.12` from BT8-gw times out

Most likely L2: VLAN 12 not actually crossing the trunk.

1. On BT8-gw: `bridge vlan show dev <BT8GW_TRUNK>` — expect VLAN 12
   listed. If absent, Phase 1.A's UCI didn't reload, or `<BT8GW_TRUNK>`
   was wrong.
2. On arseille: `bridge vlan show` — expect VLAN 12 tagged on the
   trunk ports. If absent, Phase 2.A.
3. On BT8-gw: `tcpdump -i <BT8GW_TRUNK> -nne vlan 12 and host 10.97.12.12`
   while running `ping 10.97.12.12` from another shell. Frames should
   leave BT8-gw with VLAN 12 tag.
4. On arseille (mirror port if available, or `tcpdump -i br-lan -nne`):
   verify VLAN 12 frames arriving.

If frames arrive at arseille but no reply, that's Phase 2.B (interface
not actually configured) or 2.E (firewall blocking — but it should
be disabled).

### Symptom: `ssh root@10.91.10.12` (old IP) stops working mid-runbook

Phase 2.A or 2.B disturbed the existing VLAN 10 mgmt interface.

1. Sysupgrade-restore from `arseille-pre.tar.gz` via the still-working
   path if you have one, or via serial console.
2. Re-attempt Phase 2.A with a closer read — specifically, verify
   VLAN 10 wasn't dropped from the trunk's `t` (tagged) ports while
   you were adding VLAN 12.
3. Verify 2.B added a _new_ interface and didn't edit the existing
   one in place.

### Symptom: arseille starts ECMP-ing outbound across both default routes

Phase 2.B's "Use default gateway" was left checked. Edit the new
interface, uncheck it, Save & Apply.

```sh
ip route
# should show ONE default; if two, you have the bug
```

Quick fix from CLI if LuCI is hard to reach:

```sh
ssh root@10.91.10.12 'uci set network.mgmt_new.defaultroute=0 && uci commit network && /etc/init.d/network reload'
```

### Symptom: BT8-gw can ping `10.97.12.12` but `ssh` hangs

L4 firewall on arseille is enabled and dropping. Check:

```sh
ssh root@10.91.10.12 '/etc/init.d/firewall status'
```

If active, Phase 2.E.

### Symptom: VLAN 12 frames bounce back as duplicates

The trunk between BT8-gw and arseille is forming a Layer-2 loop —
either you have two trunk ports up between the same devices, or VLAN
12 is somehow being tagged-and-untagged in a way that creates a
broadcast loop. Verify with:

```sh
bridge link show
```

on both sides and confirm STP / spanning-tree state.

### Symptom: SSH from VLAN 20/21 times out, but BT8-gw can SSH to `10.97.12.12` fine

Return-path asymmetry through thebeyond. Trace:

- SYN from workstation (e.g. `10.97.20.x`) reaches arseille via VLAN
  20 → BT8-gw → arseille on VLAN 12. Forward path works.
- SYN-ACK from arseille has `src = 10.97.12.12`, `dst = 10.97.20.x`.
  Arseille's routing lookup for `10.97.20.x`: not connected, no
  matching static — falls back to the default route via `10.91.10.1`
  (thebeyond) which is correctly still in place during the dual-stack
  window.
- Reply enters thebeyond on `brMGMT` (zone `network`). thebeyond's
  forward chain matches `network → transit` (the reply is destined
  for a subnet beyond the transit `/30`). thebeyond's `network` zone
  has `accessTo = []` and no `forwardRules.transit` — the reply is
  dropped silently (the relevant config is in
  `hosts/thebeyond/router.nix`).
- Workstation sees no SYN-ACK → TCP timeout. The giveaway versus the
  earlier "Connection refused" symptom is the **timeout** (silent
  drop on thebeyond) vs the **ICMP-error replies** (fw4 REJECT on
  arseille itself).

Confirm with `tcpdump -i any -nn port 22 and host 10.97.20.x` on
arseille while initiating SSH — you'll see the SYN arrive and a
SYN-ACK leave on `switch.10` toward thebeyond, never coming back.

**Fix: more-specific route on arseille for the bt8gw address space
via BT8-gw**, so replies to anything in `10.97.0.0/16` (and the
matching ULA block) take the symmetric path back through BT8-gw
instead of detouring via thebeyond.

LuCI — **Network → Routing → IPv4 Routes → Add**:

| Field     | Value          |
| --------- | -------------- |
| Interface | `netmgmt`      |
| Target    | `10.97.0.0/16` |
| Gateway   | `10.97.12.1`   |

And under IPv6 Routes:

| Field     | Value                      |
| --------- | -------------------------- |
| Interface | `netmgmt`                  |
| Target    | `fdc6:55f2:0a5e:1000::/52` |
| Gateway   | `fdc6:55f2:0a5e:100c::1`   |

UCI:

```sh
uci add network route
uci set network.@route[-1].interface='netmgmt'
uci set network.@route[-1].target='10.97.0.0/16'
uci set network.@route[-1].gateway='10.97.12.1'
uci add network route6
uci set network.@route6[-1].interface='netmgmt'
uci set network.@route6[-1].target='fdc6:55f2:0a5e:1000::/52'
uci set network.@route6[-1].gateway='fdc6:55f2:0a5e:100c::1'
uci commit network && /etc/init.d/network reload
```

Verify: `ip route get 10.97.20.1` on arseille should report
`via 10.97.12.1 dev switch.12`, not `via 10.91.10.1`.

At VLAN 10 retirement the `/16` static becomes redundant — the
default route flips to `10.97.12.1` and covers the same range — and
can be removed for tidiness.

---

## Appendix C — Post-runbook follow-ups

Track in [`dual-gateway-app-vlan-plan.md`](../done/dual-gateway-app-vlan-plan.md);
they're NOT part of this runbook:

- **Flake back-port** (per "Flake back-port" section above) — registry
  move + `arseille.nix` `vlanId = 12`. Single PR. Update the
  `# L2 switch (deferred reclassification)` comment on the old entry
  (delete) and add a current note on the new one.
- **Retire VLAN 10 mgmt interface** on arseille (per
  "Retiring the VLAN 10 mgmt interface" above) — ≥24h after Phase 3
  passes.
- **BT8-gw cross-VLAN forward rules** for trusted/lab/management →
  netmgmt SSH+LuCI, if/when wanted. Few-line fw4 change; no thebeyond
  involvement.
- **Update `dual-gateway-app-vlan-plan.md`** — the counterexample at
  `:217-220` ("L2 switch mgmt on network / 10 → 2 mesh hops via
  thebeyond") becomes a worked example of why netmgmt exists, since
  arseille is now its first consumer. Edit the comment in
  `lib/common/data/network.nix`'s `netmgmt = { hosts = {}; }` block
  (no longer empty).
- **Phase 4 of the dual-gateway plan** — once image-builder
  codification lands (gated on CI/CD per
  [`project_phase_4_deferred_to_cicd`](../../../.claude/projects/-home-mutantmell-git-dotfiles/memory/project_phase_4_deferred_to_cicd.md)),
  the LuCI work here becomes the test fixture for the declarative
  `mkSwitchConfig` output.
