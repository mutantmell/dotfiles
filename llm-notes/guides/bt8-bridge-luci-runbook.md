# BT8-bridge: LuCI step-by-step audit & reconcile runbook

**Status:** operator-facing runbook for bringing the already-running
BT8-bridge to the target spec for the dual-gateway plan.

**Companion runbook:** [`bt8-gateway-luci-runbook.md`](bt8-gateway-luci-runbook.md)
(the gateway side; this runbook covers the bridge side). The gateway
runbook lists "BT8-bridge is up and reachable" as a pre-flight check
— **this runbook is what makes that check pass cleanly.**

**Companion plan:** [`dual-gateway-app-vlan-plan.md`](../done/dual-gateway-app-vlan-plan.md)
(architectural reference). The plan's
[runbook A](../done/dual-gateway-app-vlan-plan.md#a-manual-setup-bt8-as-dumb-ap--wireless-bridge)
is the UCI-level target spec; this document is the LuCI-driven
operator path to it on a device that is **already partially
configured**.

**Why this runbook is different from the gateway one:**

- The device is **already running** — already has SSH, LuCI on
  `10.91.10.4`, the batman mesh up, and an existing path to thebeyond.
  This is not a fresh flash.
- The configuration target is **dramatically simpler**: one VLAN
  sub-device (`bat0.10` for the management IP), no firewall zones, no
  DHCP, no per-VLAN bridges, no client APs. Every other VLAN flows
  opaquely as batman-encapsulated, VLAN-tagged ethernet between the
  two batman hardifs (`mesh0` and the wired link to thebeyond).
- The work is **audit-first, then minimal remediation**. Each LuCI
  section below describes the target state; if the device already
  matches, skip the section. If it doesn't, apply the listed deltas.
  Most sections expect to find the device already correct.
- There is **no cable swap** in this runbook. The device stays
  physically where it is; only UCI changes via LuCI.

**Why operate via LuCI:** every change below maps to one **Save &
Apply** in LuCI. Doing it incrementally lets you verify each change in
isolation against the live mesh. Doing it all at once via UCI/SSH
would either succeed silently or fail in ways that take an external
recovery channel to debug.

**What stays working throughout this runbook:** the homelab's
existing path to thebeyond — whatever it is today (the operator's
VLAN-30 mesh-bridge workaround, or whatever else) — should continue
working. The body of this runbook is purely additive against the
target spec; the legacy VLAN-30 workaround is **not touched here**.
Decommissioning it is gated on the full dual-gateway cutover and
lives in [Appendix B](#appendix-b--retiring-the-legacy-vlan-30-non-batman-mesh).

---

## Pre-flight checklist

Tick each before touching LuCI.

- [ ] **Confirm management reachability**: `ssh root@10.91.10.4`
      succeeds from the operator's laptop (via whatever your current
      path is — VLAN-30 mesh-bridge workaround, direct cable to
      BT8-bridge's wired uplink, or otherwise).
- [ ] **Confirm LuCI reachability** at `http://10.91.10.4` (or
      `https://` if you've enabled TLS). Log in. Same browser
      session will be used throughout.
- [ ] **Take a sysupgrade backup** before any change:
      `sh
    ssh root@10.91.10.4 'sysupgrade -b /tmp/pre-runbook-backup.tar.gz'
    scp root@10.91.10.4:/tmp/pre-runbook-backup.tar.gz ~/
    `
      Save with a name like `bt8bridge-2026-MM-DD-pre-runbook.tar.gz`
      in the operator secret store. This is your one-command rollback
      if anything in this runbook goes wrong.
- [ ] **Retrieve `MESH_PSK`** from the operator secret store — only
      needed if §3.A audit finds the mesh radio PSK doesn't match the
      target spec (rare, but check). The PSK must be identical to the
      one the BT8-gateway runbook expects.
- [ ] **Confirm path to thebeyond still works** via whatever your
      current method is. Note that path so you can re-test it after
      each Save & Apply.
- [ ] **Have a second SSH session open** to BT8-bridge if possible
      (handy for running `batctl n` / `ip -br link` while making
      LuCI changes in the browser).
- [ ] **Have the [BT8-gateway runbook](bt8-gateway-luci-runbook.md)
      open in another tab** for cross-reference — several config
      parameters (mesh ID, channel, PSK, MTU) must match.
- [ ] **Have a USB-serial cable ready** as a recovery channel if LuCI
      access is lost mid-config (same caveat as the gateway runbook).

If any of the above is "no", **stop and resolve before proceeding**.

---

## Network context & state assumptions

### BT8-bridge's role (target end-state)

BT8-bridge is a **flat L2 batman-adv bridge** with two batman hard
interfaces:

- `mesh0` — 802.11s mesh radio (5 GHz, `radio1`), with
  `mesh_fwding 0` so batman handles forwarding.
- `<WIRED>` — the wired ethernet port plugged into `thebeyond`'s
  `enp2s0`. Carries batman-encapsulated, VLAN-tagged frames (**not**
  a plain 802.1Q trunk — anything that doesn't speak batman on this
  cable will not interoperate).

Both legs join `bat0`. Every VLAN that crosses the homelab
(management/11, netmgmt/12, trusted/20, lab/21, guest/30, adu/31,
iot/40, game/41, app/50, dmz/100, transit/255, plus network/10) flows
opaquely between the two hardifs as VLAN-tagged ethernet **inside**
batman. BT8-bridge does **not** need a `bat0.<vid>` sub-device for
those VLANs — batman forwards them transparently.

The **only** VLAN sub-device on this box is `bat0.10`, which carries
the management IP `10.91.10.4/24` so the operator can SSH/LuCI in.

| Item                  | Value                                         |
| --------------------- | --------------------------------------------- |
| Management IP         | `10.91.10.4/24` on `bat0.10`                  |
| Default gateway       | `10.91.10.1` (thebeyond)                      |
| DNS                   | `10.91.10.10` (phantasma)                     |
| Mesh ID               | `home-mesh`                                   |
| Mesh encryption       | WPA3-SAE (PSK = `MESH_PSK`)                   |
| Mesh forwarding       | `0` (disabled — batman handles forwarding)    |
| Routing algorithm     | `BATMAN_V`                                    |
| MTU on batman hardifs | `1536` (headroom for batman encapsulation)    |
| `firewall` service    | **disabled** (`/etc/init.d/firewall disable`) |
| `dnsmasq` service     | **disabled** (`/etc/init.d/dnsmasq disable`)  |
| `odhcpd` service      | **disabled** (`/etc/init.d/odhcpd disable`)   |
| fw4 zones             | none                                          |
| DHCP servers          | none                                          |
| Client AP SSIDs       | none                                          |

### Current state assumed at the top of this runbook

- The device is up at `10.91.10.4` and is participating in the batman
  mesh.
- The device is **also** carrying a legacy 802.11s mesh interface
  (non-batman) used for the operator's VLAN-30 mesh-bridge
  workaround to reach thebeyond from the office side. This is
  legacy; leave it in place for now.
- Some or all of the target-spec items above may already be correct;
  this runbook treats each one as a verify-then-fix.

### What this runbook does **not** do

- It does **not** flash, sysupgrade, or otherwise change firmware.
  If the device needs reflashing, that's a separate (much higher
  risk) operation — back up the config, do the flash, then run this
  runbook to re-apply the configuration on the flashed device.
- It does **not** touch the legacy VLAN-30 non-batman mesh. That
  decommission is [Appendix B](#appendix-b--retiring-the-legacy-vlan-30-non-batman-mesh),
  gated on the full dual-gateway cutover.
- It does **not** add `bat0.<vid>` for any VLAN other than `10`. The
  BT8-gateway runbook's §5.E adds `bat0.<vid>` for many VLANs **on
  BT8-gateway**; that's not needed here. BT8-bridge is L2-only.

### Stopping points

The runbook is a single audit pass through the LuCI surface. Each
sub-step ends in a Save & Apply (or "nothing to change, move on"),
and any of them is a safe pause point — the device's current
config remains intact while you stop. Most sub-steps expect to make
no change.

---

## Window structure

Approximate duration: **30–60 minutes** of LuCI work, assuming the
device's current state is close to the target. If the audit finds
substantial divergence, plan for longer.

This runbook is **not a maintenance window** in any conventional
sense:

- The device stays where it is, plugged into what it's plugged into.
- No cable swap, no firmware flash, no physical relocation.
- Each Save & Apply is reversible by restoring the pre-runbook
  backup taken in pre-flight.
- The legacy VLAN-30 workaround continues to carry the operator's
  current path to thebeyond throughout the runbook.

The discrete phases:

1. **Phase 1** — Pre-flight audit. Dump current config; identify
   what already matches the target and what doesn't. No changes.
2. **Phase 2** — Apply deltas via LuCI, one Save & Apply per
   sub-step (§3.A through §3.G).
3. **Phase 3** — End-of-runbook verification and final config
   backup.

Appendix B is a **separate later window**, gated on the BT8-gateway
runbook having completed and the new mesh path having been verified
end-to-end for ≥24 hours.

---

## Phase 1 — Pre-flight audit (current-state dump)

SSH into BT8-bridge from the operator laptop:

```sh
ssh root@10.91.10.4
```

Dump the current network/wireless/firewall config to compare against
the target spec:

```sh
uci show network
uci show wireless
uci show firewall
uci show dhcp
```

Note specifically:

- Which radio (`radio0`/`radio1`/`radio2`) hosts the batman mesh
  (`option mode 'mesh'`, `option mesh_id 'home-mesh'`).
- Which radio (if any) hosts the **legacy** non-batman mesh — likely
  a separate `wifi-iface` block with a different `mesh_id`, or with
  `option mesh_fwding '1'`, or attached to a network that's not a
  `batadv_hardif`.
- Which physical port (`lan1`, `lan2`, etc.) is the wired link to
  thebeyond. Look for the `interface` block with
  `option proto 'batadv_hardif'` that's not `mesh0`. The port name
  there is what this runbook will call `<WIRED>` (defaults to `lan1`
  per the plan's runbook A).
- Whether `firewall`, `dnsmasq`, `odhcpd` are enabled.

Also dump runtime state:

```sh
ip -br link
ip -4 addr show
ip -6 addr show
batctl if
batctl n
batctl o
/etc/init.d/firewall status
/etc/init.d/dnsmasq status
/etc/init.d/odhcpd status
```

Save this output to a scratch file on your laptop — you'll want it
to compare against the post-runbook state.

### 1.1 Identify any divergences from target spec

Using the dumps above, walk down this checklist and note which items
need remediation:

- [ ] **Mesh radio** (§3.A): `mesh_id 'home-mesh'`, encryption SAE,
      `mesh_fwding 0`, channel matches BT8-gateway plan.
- [ ] **Mesh interface** (§3.B): `batadv_hardif` proto, master `bat0`,
      MTU 1536.
- [ ] **Wired hardif** (§3.B): `batadv_hardif` proto, master `bat0`,
      MTU 1536, `ifname <WIRED>` (the port plugged into thebeyond).
- [ ] **`bat0` interface** (§3.C): `batadv` proto, `BATMAN_V`,
      `gw_mode off`.
- [ ] **`bat0.10` device + management interface** (§3.D): VLAN device
      on `bat0` with VID 10, plus a static interface bound to it with
      IP `10.91.10.4/24`, gateway `10.91.10.1`, DNS `10.91.10.10`.
- [ ] **No other `bat0.<vid>` devices** (§3.E). If any exist (e.g.,
      `bat0.30` from the workaround), leave them in place for now —
      Appendix B handles their removal.
- [ ] **`firewall` service disabled** (§3.F).
- [ ] **`dnsmasq` service disabled** (§3.F).
- [ ] **`odhcpd` service disabled** (§3.F).
- [ ] **Default `wan` interface removed** (§3.G). No `wan` on this
      device.
- [ ] **fw4 zones removed** (§3.G). With `firewall` disabled, zones
      are inert anyway, but a clean device has none.

Each ticked item is a no-op in Phase 2. Each unticked item gets the
matching §3.X treatment.

---

## Phase 2 — Apply deltas via LuCI

Each sub-step below describes the target state and the LuCI path to
get there. If the audit in §1.1 confirmed the current state already
matches, **skip the sub-step**. If not, apply only what's missing
and Save & Apply.

> **A note on ordering.** The sub-steps are ordered safest-to-riskiest
> from the perspective of preserving the operator's current management
> path. §3.A through §3.E only touch additive / verify-only state.
> §3.F (service disable) is harmless if the services aren't doing
> anything anyway. §3.G (removing `wan`/`lan`/fw4 zones) is the
> riskiest because it can affect what the device responds to on
> `192.168.1.1` — read the warnings inline.

### 3.A — Verify (or correct) the mesh radio

**Network → Wireless.**

Find the SSID-or-mesh entry on `radio1` (5 GHz) that hosts the
**batman** mesh. It should have:

- **General Setup** tab:
  - **Mode**: `802.11s`
  - **Mesh ID**: `home-mesh`
  - **Network**: `mesh` (a network entry of proto `batadv_hardif`
    pointing to `bat0`)
  - **Channel**: same channel as BT8-gateway's plan. Confirm with
    the BT8-gateway runbook §5.A.
- **Wireless Security** tab:
  - **Encryption**: `WPA3-SAE`
  - **Key**: `MESH_PSK` from the operator secret store
- **Advanced Settings** tab:
  - **Mesh Forwarding**: `0` (disabled — batman-adv handles
    forwarding)

If all of these already match, **skip this sub-step**.

If any one differs:

> ⚠️ **Risk**: changing mesh parameters on a live device will drop
> the mesh briefly while the radio reassociates. If BT8-bridge is
> the operator's only path to thebeyond via the workaround, this can
> cut off the operator's SSH session to thebeyond. The session to
> BT8-bridge itself is **not** at risk — the operator's path to
> BT8-bridge is independent of the mesh.

Make the change, **Save** the wifi-iface, **Save & Apply** the page.
Wait ~30s, then re-verify in SSH:

```sh
batctl n     # neighbours should reappear; expect at least thebeyond
             # (via the wired hardif — present regardless of mesh state)
iw dev mesh0 info | grep -E '(ssid|channel|mesh_id)'
```

**Do not proceed past §3.A if `batctl n` no longer lists thebeyond
via the wired hardif** — that means the wired link is broken
(unrelated to mesh; see §3.B).

### 3.B — Verify the batman hardifs (mesh + wired)

**Network → Interfaces → Devices** tab.

There should be two `batadv_hardif` interfaces:

1. **`mesh` interface** (the mesh radio's network binding):
   - **Protocol**: `Batman-adv hardif`
   - **Master**: `bat0`
   - **MTU**: `1536` (set on the underlying device, not the interface
     — Devices tab → edit `mesh` device → MTU 1536)

2. **Wired interface** (the link to thebeyond):
   - **Protocol**: `Batman-adv hardif`
   - **Master**: `bat0`
   - **MTU**: `1536` (set on the underlying device — Devices tab →
     edit `<WIRED>` device → MTU 1536)
   - **ifname**: `<WIRED>` (the port plugged into thebeyond, default
     `lan1`)

If both already exist and match, **skip this sub-step**.

> ⚠️ **Risk**: the wired hardif is the link to thebeyond. If you
> change its `ifname` to the wrong port, or change its proto away
> from `batadv_hardif`, you lose thebeyond reachability for the rest
> of the runbook (and break the homelab's path to internet, depending
> on which workaround is in play). **Confirm the port name twice
> against the audit dump in Phase 1.**

To add a missing one:

**Network → Interfaces → Add new interface...**

- **Name**: `mesh` (or `wired`, matching the slot you're filling)
- **Protocol**: `Batman-adv hardif`
- **Device**: the underlying device (the mesh interface name from
  the wireless tab, or `<WIRED>`)
- **Master**: `bat0`

Click **Create interface**. **Save & Apply.**

Verify:

```sh
batctl if     # expect both mesh0 and <WIRED> listed as hardifs
```

### 3.C — Verify `bat0`

**Network → Interfaces.**

Find the `bat0` interface. It should have:

- **Protocol**: `Batman-adv`
- **Advanced Settings** tab:
  - **Routing algorithm**: `BATMAN_V`
  - **Gateway mode**: `off`

If it already matches, **skip**.

If `bat0` is missing entirely (very unlikely on an already-meshing
device, but check), create it:

**Network → Interfaces → Add new interface...**

- **Name**: `bat0`
- **Protocol**: `Batman-adv`

Click **Create interface**, set Advanced Settings as above,
**Save & Apply.**

### 3.D — Verify `bat0.10` + management interface

**Network → Interfaces → Devices** tab.

There should be a VLAN device:

- **Type**: `VLAN (802.1q)`
- **Base device**: `bat0`
- **VLAN ID**: `10`
- **Name**: `bat0.10` (auto-filled)

**Network → Interfaces** tab.

There should be a `mgmt` interface (or whatever the operator named
it — likely just bound to `bat0.10`):

- **Protocol**: `Static address`
- **Device**: `bat0.10`
- **IPv4 address**: `10.91.10.4`
- **IPv4 netmask**: `255.255.255.0`
- **IPv4 gateway**: `10.91.10.1`
- **DNS servers**: `10.91.10.10`

If all of this matches, **skip this sub-step**. This is the most
critical piece of working state to leave alone — it's the operator's
SSH/LuCI surface.

> ⚠️ **Risk**: if you change the IP, netmask, or device binding
> here, the LuCI session that's making the change loses connectivity
> mid-Save. **Do not change this interface unless the audit found a
> genuine divergence.** If you must change it, plan the recovery path
> in advance (serial console, or known-good config snapshot to
> sysupgrade back to).

### 3.E — Verify no other `bat0.<vid>` devices exist

**Network → Interfaces → Devices** tab.

Filter for devices whose base is `bat0`. Only `bat0.10` should be
present.

If you see additional ones (e.g., `bat0.30` from the workaround,
`bat0.50` from an experimental setup, etc.):

- **Do not remove them in this runbook.** They're likely tied to
  the legacy non-batman mesh / VLAN-30 workaround, which is the
  scope of [Appendix B](#appendix-b--retiring-the-legacy-vlan-30-non-batman-mesh).
- Note them in your scratch file so Appendix B's audit can pick
  them up later.

**No Save & Apply for this sub-step.**

### 3.F — Verify gateway-only services are disabled

In SSH:

```sh
/etc/init.d/firewall status
/etc/init.d/dnsmasq  status
/etc/init.d/odhcpd   status
```

All three should report inactive / disabled.

If any are running:

```sh
/etc/init.d/firewall stop && /etc/init.d/firewall disable
/etc/init.d/dnsmasq  stop && /etc/init.d/dnsmasq  disable
/etc/init.d/odhcpd   stop && /etc/init.d/odhcpd   disable
```

Cross-check:

```sh
/etc/init.d/firewall enabled || echo "firewall: disabled (OK)"
/etc/init.d/dnsmasq  enabled || echo "dnsmasq:  disabled (OK)"
/etc/init.d/odhcpd   enabled || echo "odhcpd:   disabled (OK)"
```

`enabled` returns non-zero on a disabled service — the `||` prints
the OK message.

> Note: disabling these services is **safe** on a live device because
> nothing depends on them in the bridge role. The dnsmasq DHCP server
> isn't serving any clients (everything DHCPs from thebeyond), and
> the firewall isn't enforcing any rules that the operator cares
> about (BT8-bridge does no L3 forwarding). The
> [Reference F.3](../done/dual-gateway-app-vlan-plan.md#f3-role-specific-service-activation)
> table in the plan documents this explicitly.

### 3.G — Remove the default `wan` interface and any stale fw4 zones

**Network → Interfaces.**

There may be a default `wan` interface left over from the device's
factory config. BT8-bridge does **not** have a wan — its uplink is
the batman wired hardif. Click **Remove** on the `wan` interface if
present.

**Network → Interfaces → Devices** tab.

Remove any leftover `br-wan` bridge device if present.

**Network → Firewall.**

With `firewall` disabled in §3.F, fw4 zones are inert. But a clean
device shouldn't have any. **Delete every zone**: `lan`, `wan`, plus
any leftover custom zones. Save & Apply.

> ⚠️ **`lan` zone caveat**: the default `lan` zone covers the
> default `br-lan` interface, which by default has `192.168.1.1`.
> If your laptop has historically used `192.168.1.1` as the emergency
> console path (laptop cable into the BT8's LAN port), removing the
> `lan` zone is harmless (fw is disabled), but **removing the `lan`
> interface itself** also removes `192.168.1.1` from the device. On
> BT8-bridge this is fine — emergency access goes via the management
> VLAN (`10.91.10.4`) or serial console — but make the call
> explicitly.

You have two options:

- **A: Keep `lan` interface + `br-lan` for emergency console access**
  (laptop direct cable to a free LAN port, falls back to
  `192.168.1.1`). Cost: one wired LAN port permanently dedicated;
  minor surface area (LuCI listens on 192.168.1.1 with only physical
  access). Match what's already on BT8-gateway §7.1 if applicable.
- **B: Remove `lan` interface entirely**, leaving only management
  VLAN access at `10.91.10.4`. Cleaner; loses the emergency cable
  path. Serial console remains.

**Recommended: A** to mirror BT8-gateway's emergency-access posture,
until codification in Phase 4 of the plan establishes a different
norm.

If keeping `lan`, leave it as-is. If removing it: **Network →
Interfaces → Remove on `lan`**, then **Network → Interfaces →
Devices → Remove on `br-lan`**. **Save & Apply.**

**Save & Apply** the firewall page.

---

## Phase 3 — End-of-runbook verification

In SSH on BT8-bridge:

```sh
# batman fabric: both hardifs present, both peers visible
batctl if                            # mesh0 + <WIRED> both listed
batctl n                             # neighbours: thebeyond (via <WIRED>),
                                     # plus any office-side mesh peers
                                     # (incl. BT8-gateway once it's up)
batctl o                             # originator table covers the fabric

# only bat0.10 has an IP; nothing else has L3
ip -4 addr show | grep -E 'inet '    # exactly one inet line — 10.91.10.4/24
                                     # (plus 192.168.1.1 if you kept br-lan)
ip -6 addr show | grep -E 'inet6 '   # only link-local + the mgmt v6 (if any)
                                     # — no per-VLAN bridges

# services are dead
/etc/init.d/firewall status          # inactive
/etc/init.d/dnsmasq  status          # inactive
/etc/init.d/odhcpd   status          # inactive

# VLAN traffic crossing
tcpdump -i bat0 -nne -c 10           # mixed VLAN tags expected — every
                                     # carried VLAN flows through bat0
                                     # without local termination

# routing — minimal, just the management default
ip route                             # default via 10.91.10.1 dev bat0.10
ip -6 route                          # ULA + link-local routes only
```

From the operator's laptop:

```sh
ssh root@10.91.10.4                  # still works
ping 10.91.10.4                      # still works from network/10
```

From `thebeyond` (over the operator's current path):

```sh
ssh root@thebeyond 'batctl n'        # BT8-bridge should appear via the
                                     # wired hardif
```

**If any of the above fails, restore from backup:**

```sh
sysupgrade -r /tmp/pre-runbook-backup.tar.gz
```

(or scp the backup back from your laptop if `/tmp` got cleared)

### Post-runbook config backup

```sh
sysupgrade -b /tmp/post-runbook-backup.tar.gz
```

```sh
scp root@10.91.10.4:/tmp/post-runbook-backup.tar.gz ~/
```

Save with a name like `bt8bridge-2026-MM-DD-post-runbook.tar.gz` in
the operator secret store. This is your "known good" snapshot for
any future revert.

---

## Cross-reference: BT8-gateway runbook prerequisite gate

The [BT8-gateway runbook's pre-flight](bt8-gateway-luci-runbook.md#pre-flight-checklist-do-before-you-start-the-window)
includes:

> Confirm BT8-bridge is up and reachable. From any host that can
> still reach it (e.g., your laptop via legacy BT8 + mesh):
> `ssh root@10.91.10.4 'batctl n'`. The new BT8-gateway needs
> BT8-bridge as its mesh peer to join.

After this runbook completes, that prerequisite check passes
cleanly: BT8-bridge's mesh radio is on the right channel with the
right PSK and the right mesh ID, batman is up on both hardifs,
and thebeyond is reachable via the wired hardif.

You can now schedule the BT8-gateway runbook independently.

---

## Appendix A — Reference data table

Print this and keep it next to the laptop.

### Addressing (BT8-bridge, target end-state)

| Item                         | Value                                    |
| ---------------------------- | ---------------------------------------- |
| Management IP                | `10.91.10.4/24` on `bat0.10`             |
| Default gateway              | `10.91.10.1` (thebeyond)                 |
| DNS                          | `10.91.10.10` (phantasma)                |
| Emergency console (optional) | `192.168.1.1` on `br-lan` (laptop cable) |

### Mesh parameters (must match BT8-gateway)

| What                       | Value                                          |
| -------------------------- | ---------------------------------------------- |
| Mesh ID                    | `home-mesh`                                    |
| Encryption                 | `WPA3-SAE`                                     |
| Mesh forwarding            | `0` (disabled — batman-adv handles forwarding) |
| Routing algo               | `BATMAN_V`                                     |
| MTU on mesh / wired hardif | `1536`                                         |
| Gateway mode (batman)      | `off`                                          |

### Service state

| Service    | State        |
| ---------- | ------------ |
| `firewall` | **disabled** |
| `dnsmasq`  | **disabled** |
| `odhcpd`   | **disabled** |

### Hardifs on `bat0`

| Hardif                | Purpose                            |
| --------------------- | ---------------------------------- |
| `mesh0`               | 802.11s mesh — wireless leg        |
| `<WIRED>` (e.g. lan1) | Wired link to thebeyond's `enp2s0` |

### Reachable peers (verify via `batctl n`)

| Peer                 | Via       | Notes                                  |
| -------------------- | --------- | -------------------------------------- |
| `thebeyond`          | `<WIRED>` | always present once wired hardif is up |
| `BT8-gateway`        | `mesh0`   | appears post-§5.D of gateway runbook   |
| office-side dumb APs | `mesh0`   | per the mesh-placement principle       |

### LuCI menu cheat-sheet

| Task                          | LuCI path                                                |
| ----------------------------- | -------------------------------------------------------- |
| SSH keys / root password      | System → Administration                                  |
| Set hostname / timezone       | System → System → General Settings                       |
| Mesh wifi                     | Network → Wireless → Edit on `radio1` mesh interface     |
| VLAN device / hardif          | Network → Interfaces → Devices tab                       |
| Interface (assign IP/proto)   | Network → Interfaces                                     |
| Firewall (zones — verify off) | Network → Firewall                                       |
| Service enable/disable        | System → Startup, or `/etc/init.d/<svc> disable` via SSH |
| Backup config                 | System → Backup / Flash Firmware                         |

---

## Appendix B — Retiring the legacy VLAN-30 non-batman mesh

> ⚠️ **Do not perform any of these steps until ALL of these hold:**
>
> 1. The [BT8-gateway runbook](bt8-gateway-luci-runbook.md) has run
>    end-to-end, including the §6 cable swap and §6.3 post-swap
>    passthrough regression check.
> 2. The operator has verified normal SSH/admin access to thebeyond
>    via the new mesh path — **not** via the VLAN-30 workaround.
>    Confirm by temporarily disabling the workaround's non-batman
>    mesh radio and verifying thebeyond is still reachable from the
>    homelab. Re-enable the radio after the check.
> 3. At least **24 hours** of stable post-cutover operation with
>    real homelab traffic crossing the new fabric, with no operator
>    intervention.
>
> If any of the above is "no", stop. The workaround is harmless
> while idle; removing it prematurely loses an emergency path
> back to thebeyond.

### B.1 — Identify the legacy mesh and its bridge

In SSH on BT8-bridge:

```sh
uci show wireless | grep -E '(mesh_id|mesh_fwding|encryption|key)'
uci show network  | grep -E '(bat0\.|br-v|proto|members)'
```

The legacy mesh is the `wifi-iface` whose:

- `mesh_id` is **not** `home-mesh`, OR
- `mesh_fwding` is `1` (forwarding enabled — non-batman path), OR
- whose `network` setting points to an interface that is **not**
  `batadv_hardif` proto.

Identify also the bridge (likely `br-v30` or similar) that combines
the legacy mesh's network with something on the wired side (a
`bat0.30` sub-device, or a direct `lan?.30`).

Note the exact `wifi-iface` name, `interface` name, `device` (bridge)
name, and any associated `bat0.<vid>` device that exists only to
support the workaround.

### B.2 — Take a pre-decommission backup

```sh
sysupgrade -b /tmp/pre-decom-backup.tar.gz
scp root@10.91.10.4:/tmp/pre-decom-backup.tar.gz ~/
```

Save with a name like `bt8bridge-2026-MM-DD-pre-decom.tar.gz`.

### B.3 — Disable (do not delete) the legacy mesh radio

**Network → Wireless.** Find the legacy mesh `wifi-iface`. Click
**Disable** (not Remove). **Save & Apply.**

Disabling rather than removing is deliberate: it kills the radio
without touching surrounding config. If anything breaks, re-enabling
is one click.

### B.4 — Verify everything still works

Wait 5 minutes for any in-flight legacy-mesh traffic to either
reroute or fail.

From the operator's laptop and from a host on `trusted`/20:

```sh
ping thebeyond                       # via the new mesh path
nslookup example.com                 # DNS still works
ping 1.1.1.1                         # internet still works
ssh root@thebeyond                   # SSH works via the new path
```

From BT8-bridge:

```sh
batctl n                             # thebeyond + BT8-gateway present
batctl o                             # full originator table
```

**If anything breaks**, re-enable the legacy mesh radio in LuCI
(**Wireless → Enable**, Save & Apply) and investigate offline. Do
not proceed to §B.5.

### B.5 — Remove the legacy bridge and `bat0.<vid>` (if any)

Once §B.4 has been stable for **another 24 hours** with the legacy
radio disabled:

**Network → Interfaces.** Remove the interface bound to the legacy
bridge (e.g., `v30`, or whatever it was named).

**Network → Interfaces → Devices** tab. Remove the bridge device
(e.g., `br-v30`).

If there was a `bat0.<vid>` device created **solely** to support
the workaround (i.e., not `bat0.10`, which is for management), remove
it too.

**Save & Apply** after each removal.

Re-run §B.4's verification block. Then:

### B.6 — Remove the legacy mesh `wifi-iface` entirely

**Network → Wireless.** Now click **Remove** on the (already-disabled)
legacy mesh `wifi-iface`. **Save & Apply.**

### B.7 — Post-decommission backup

```sh
sysupgrade -b /tmp/post-decom-backup.tar.gz
scp root@10.91.10.4:/tmp/post-decom-backup.tar.gz ~/
```

Save with a name like `bt8bridge-2026-MM-DD-post-decom.tar.gz`.

At this point BT8-bridge is at its **clean target end-state**:

```
mesh0   ──┐
          ├── bat0 ── bat0.10 ── (mgmt: 10.91.10.4/24)
<WIRED> ──┘
```

No other VLAN sub-devices, no bridges, no firewall, no DHCP, no
extra wireless interfaces.

### B.8 — Update CLAUDE.md / project memory

If the workaround was documented anywhere in the project (the
plan's pre-flight references, CLAUDE.md notes, etc.), strike those
references — the workaround no longer exists. The BT8-gateway
runbook's pre-flight item about the VLAN-30 mesh-bridge workaround
becomes obsolete after this appendix completes; cross out or remove
that bullet in a follow-up commit.

---

## Appendix C — Troubleshooting

### Symptom: `batctl n` stops listing thebeyond after a §3.X change

The wired hardif lost its batman attachment. Check, in order:

1. `batctl if` — is `<WIRED>` still listed as a hardif?
2. `uci show network | grep <WIRED>` — did the proto change away
   from `batadv_hardif`?
3. `ip -d link show dev <WIRED>` — is the device up?
4. `ip -d link show dev <WIRED> | grep master` — does it report
   `master bat0`?
5. On thebeyond: `batctl n` — does it still see BT8-bridge?

If §3.B was the most recent change, undo it (Devices tab → Edit →
restore previous values; or `sysupgrade -r pre-runbook-backup.tar.gz`).

### Symptom: `batctl n` stops listing BT8-gateway / office-side mesh peers

Mesh radio config changed in a way that broke the mesh. Check:

1. `iw dev mesh0 info` — confirm channel, mesh_id, encryption match
   the BT8-gateway plan.
2. `iw dev mesh0 station dump | grep signal:` — confirm RF signal
   (≥ −75 dBm for usable throughput).
3. Verify `MESH_PSK` exactly matches across all mesh peers.
4. `wifi down; wifi up` — force radio re-init.

If §3.A was the most recent change, undo it.

### Symptom: lost LuCI / SSH access mid-runbook

In order:

1. Did the change touch `bat0.10` or the management interface
   binding? If yes, restore via serial console:
   `vi /etc/config/network`, fix the interface stanza,
   `service network reload`.
2. Did the change touch the `lan` interface (`br-lan` /
   `192.168.1.1`)? If yes, and you kept emergency-console access,
   plug your laptop into a free LAN port and try `192.168.1.1`.
3. Failing both: restore from backup via serial:
   `sysupgrade -r /path/to/pre-runbook-backup.tar.gz`. The backup
   file may need to be `scp`'d to the device from another host on
   the same physical L2 segment first.

### Symptom: BT8-gateway runbook's §5.D mesh checkpoint fails after this runbook

The BT8-gateway runbook's §5.D verifies `batctl n` lists BT8-bridge.
If that fails:

1. On BT8-bridge: `batctl if` should list `mesh0` as a hardif —
   if not, redo §3.B.
2. On BT8-bridge: `iw dev mesh0 info` should match channel + mesh_id
   - encryption with BT8-gateway's wireless config — if not, redo
     §3.A.
3. RSSI check from BT8-gateway side (per BT8-gateway runbook §5.D
   troubleshooting): `iw dev mesh0 station dump | grep signal:` —
   if ≪ −75 dBm, RF problem (relocate / antenna / interference),
   not a config problem.

### Symptom: legacy VLAN-30 workaround broken after running this runbook

The body of this runbook is **not supposed to touch the workaround**.
If it broke:

1. Check whether §3.G removed a bridge or interface the workaround
   depended on. The most likely candidate is a leftover bridge that
   wasn't recognized as part of the workaround during the audit.
2. Restore from `pre-runbook-backup.tar.gz`.
3. Re-run Phase 1 audit more carefully, paying attention to any
   bridge / interface / `bat0.<vid>` you didn't recognize.

---

## Appendix D — Post-runbook follow-ups

Track these in the project's existing checklist (likely
[`dual-gateway-app-vlan-checklist.md`](../done/dual-gateway-app-vlan-checklist.md));
they are NOT part of running this runbook:

- Save the post-runbook sysupgrade backup into the operator secret
  store.
- Schedule the [BT8-gateway runbook](bt8-gateway-luci-runbook.md) —
  this runbook unblocks its pre-flight gate.
- Schedule Appendix B for ≥24 hours after BT8-gateway cutover plus
  full passthrough regression check. Do **not** combine into the
  same maintenance window as BT8-gateway.
- Schedule Phase 4 of the plan (Image Builder codification of
  BT8-bridge — once stable, the manual UCI captured here becomes
  the test fixture for the declarative build).
- File a project memory if anything unexpected was found during the
  audit (so future Claude knows the device's idiosyncrasies).
