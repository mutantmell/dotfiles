# BT8-gateway: LuCI step-by-step build & cutover runbook

**Status:** operator-facing runbook for the BT8-gateway hardware cutover
during the dual-gateway migration. Read end-to-end before starting.

**Companion plan:** [`dual-gateway-app-vlan-plan.md`](dual-gateway-app-vlan-plan.md)
(architectural reference; do not need to follow during the window).
**Companion checklist:** [`dual-gateway-app-vlan-checklist.md`](dual-gateway-app-vlan-checklist.md)
(maps to plan phases; this runbook covers Phase 0b ("Hardware cutover")
and the manual side of Phase 2 ("BT8-gateway by hand") for the
**BT8-gateway** role specifically).

**Why operate via LuCI:** every step below maps to one **Save & Apply**
in LuCI. Doing it incrementally lets you verify each change in
isolation. Doing it all at once via UCI/SSH would either succeed
silently or fail in ways that take an external recovery channel to
debug — and during this window you do not have one.

**Why this is dangerous:** during the window, the office homelab loses
internet and inter-VLAN routing. You will not have your usual Claude
Code workflow available for debugging. Your laptop directly cabled to
the BT8 (LuCI on `192.168.1.1`) is the only management surface for the
duration. Treat every Save & Apply as a checkpoint.

---

## Pre-flight checklist (do BEFORE you start the window)

Tick each before powering anything off.

- [ ] **Print or save this document offline** (PDF, phone screenshot,
      paper). Once you cut the internet, you cannot re-fetch it.
- [ ] **Print or save the [reference data table](#appendix-a-reference-data-table)**
      separately for fast lookup.
- [ ] **Retrieve secrets** from the operator secret store:
  - [ ] `MESH_PSK` — SAE pre-shared key for `home-mesh` (must match
        BT8-bridge and any office mesh APs already deployed)
  - [ ] WiFi PSKs for any client SSIDs you intend to bring up
        (HOME, GUEST, IOT, GAME) — only the ones you'll configure today
  - [ ] Root password to set on first boot
  - [ ] Your SSH public key (for key-based root access)
- [ ] **Build the image (Phase 1 below) AHEAD OF TIME**, while internet
      is still available. Save both `factory.bin` and `sysupgrade.bin` to
      your laptop's local disk. Do not rely on being able to download
      during the window.
- [ ] **Save the legacy BT8's `sysupgrade.bin`** (the one it's running
      right now, in its gateway role) onto your laptop. This is your
      emergency reflash image _if_ the cable-swap-back rollback (§6.5)
      doesn't restore service for some unforeseen reason and you need to
      rebuild legacy from clean state. The expected rollback path is just
      unplugging the new BT8 and plugging the legacy one back in — but
      having the image as a backstop costs nothing.
- [ ] **Have a USB-serial cable** ready and tested against the BT8's
      serial header (3.3V; baud rate per device docs — typically 115200
      8N1). This is your recovery path if LuCI access on the new BT8 is
      lost during config.
- [ ] **Stage hardware**: the **spare BT8** in the office (the one to
      be flashed), ethernet patch cable from its `lan2` port to your
      laptop, power supply. The **legacy BT8 stays in place** and
      continues to serve homelab traffic for the entire duration of
      Phase 1–5; it is only disconnected at §6 cable swap.
- [ ] **Confirm BT8-bridge is up and reachable.** From any host that
      can still reach it (e.g., your laptop via legacy BT8 + mesh):
      `ssh root@10.91.10.4 'batctl n'`. The new BT8-gateway needs
      BT8-bridge as its mesh peer to join.
- [ ] **Confirm `thebeyond` transit IP is up**: `ping 10.255.255.1`
      from whichever host you currently have a reliable path to thebeyond
      from. **Note** for this deployment specifically: thebeyond is not
      yet reachable via a normal SSH path; the operator is currently
      using a VLAN 30 mesh-bridge workaround (the existing non-batman
      mesh patched into VLAN 30, which is the only VLAN safe to bridge
      because legacy BT8 doesn't own `10.97.30.0/24`). That hack is
      acceptable for this verification check — what matters is that
      thebeyond's transit interface answers, not which path you use to
      test it. The hack becomes obsolete after §6 cutover, when the
      homelab reaches thebeyond cleanly via mesh through BT8-gateway.
- [ ] **Confirm the plan's Phase 1 is deployed** (registry+thebeyond
      config redeployed). The cable swap in §6 only works because
      thebeyond is already serving L3 for all of the homelab's VLANs
      (10.97.10/11/20/21/100 + APP/50 + transit/255) over the mesh; if
      Phase 1 isn't deployed, the swap goes to a thebeyond that doesn't
      know about half the homelab's address space and traffic black-holes.
      See [plan §Phase 1](../wip/dual-gateway-app-vlan-plan.md#phase-1--add-app-and-transit-vlans-to-the-registry-and-thebeyond)
      for the exact zone/route set; the prerequisite gate inside the plan
      ([§Phase 2 prerequisites](../wip/dual-gateway-app-vlan-plan.md#phase-2--manual-proof-bt8-bridge-and-bt8-gateway))
      enumerates the checks.
- [ ] **Take photos** of the legacy BT8's current cabling so you can
      rebuild it identically if you have to roll the §6 swap back and
      fully revert to legacy.
- [ ] **No general homelab announcement needed** for this runbook —
      Phases 1–5 happen on the spare BT8 with no production impact. The
      §6 swap is a few-seconds cable change; briefly notify anyone
      actively using the homelab in case they see a single dropped
      connection, but no maintenance window required.

If any of the above is "no", **stop and resolve before proceeding**.

---

## Network context & state assumptions

**Read this before the window opens.** This runbook covers the
**Phase 2** scope of the [dual-gateway migration
plan](../wip/dual-gateway-app-vlan-plan.md): bringing BT8-gateway up
as the L3 gateway for **APP (VLAN 50)** and **transit (VLAN 255)
only**. L3 ownership of `management`/11, `trusted`/20, `lab`/21,
`netmgmt`/12 stays on `thebeyond` until Phase 3, which is a separate
later window covered by its own (future) cutover runbook.

### Devices and current L3 ownership (the state this runbook assumes)

| Device                      | Role                                                                                                                    | Where it's reachable                                                                               |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `thebeyond`                 | Internet gateway + WAN/NAT + most L3s                                                                                   | `10.91.10.1` (network); `10.255.255.1` (transit)                                                   |
| `BT8-bridge`                | Wireless bridge — L2 passthrough only                                                                                   | `10.91.10.4` (network)                                                                             |
| legacy BT8                  | **Still in production** as the office gateway. Stays running through §5; cable-swapped out at §6; decommissioned at §7. | whatever IP it currently serves homelab on (typically `10.97.11.1` / `10.97.20.1` / etc.)          |
| spare BT8 (new BT8-gateway) | The device being flashed by this runbook. On the operator's laptop cable during §1–§5; joins the homelab trunk at §6.   | `192.168.1.1` (default LuCI on laptop cable) during config; `10.97.50.1` + `10.255.255.2` after §6 |

L3 ownership by VLAN as of _right now_ (verify before starting — if
any of this is wrong, the rollout has a pre-existing inconsistency
that must be resolved first):

| VLAN | Zone       | Subnet            | L3 lives on      | Permanent home / migration note                           |
| ---- | ---------- | ----------------- | ---------------- | --------------------------------------------------------- |
| 10   | network    | `10.91.10.0/24`   | `thebeyond`      | permanent — stays on `thebeyond` forever                  |
| 11   | management | `10.97.11.0/24`   | `thebeyond`      | moves to BT8-gateway in **Phase 3**                       |
| 12   | netmgmt    | (new)             | (none yet)       | added on BT8-gateway in **Phase 3**                       |
| 20   | trusted    | `10.97.20.0/24`   | `thebeyond`      | moves to BT8-gateway in **Phase 3**                       |
| 21   | lab        | `10.97.21.0/24`   | `thebeyond`      | moves to BT8-gateway in **Phase 3**                       |
| 30   | guest      | `10.91.30.0/24`   | `thebeyond`      | permanent                                                 |
| 31   | adu        | `10.91.31.0/24`   | `thebeyond`      | permanent                                                 |
| 40   | iot        | `10.91.40.0/24`   | `thebeyond`      | permanent                                                 |
| 41   | game       | `10.91.41.0/24`   | `thebeyond`      | permanent                                                 |
| 50   | app        | (new)             | (none yet)       | **added on BT8-gateway by this runbook**                  |
| 100  | dmz        | `10.97.100.0/24`  | `thebeyond`      | permanent through Phase 5; later renumbers to `10.91.100` |
| 255  | transit    | `10.255.255.0/30` | `thebeyond` (.1) | **BT8-gateway picks up .2 in this runbook**               |

(Phase 1 of the plan already added `app`, `netmgmt`, and `transit`
zones to `thebeyond`'s NixOS config: APP and NETMGMT as member-only
bridges with no IP on `thebeyond`, transit with `10.255.255.1/30`.)

### Target state (when this runbook completes)

BT8-gateway will be the L3 gateway for **only**:

| VLAN | Zone    | IPv4              | IPv6                        |
| ---- | ------- | ----------------- | --------------------------- |
| 50   | app     | `10.97.50.1/24`   | `fdc6:55f2:0a5e:1032::1/64` |
| 255  | transit | `10.255.255.2/30` | `fdc6:55f2:0a5e:ffff::2/64` |

All other VLANs on BT8-gateway will be **L2-passthrough**: the bridge
exists so mesh-side (`bat0.<vid>`) and wired-trunk-side
(`<TRUNK>.<vid>`) frames can meet, but BT8-gateway holds **no IP,
no fw4 zone, no DHCP** on them. L3 for those VLANs keeps living on
`thebeyond` until Phase 3.

**Importantly:** this runbook **does not create bridges or zones for
management/11, trusted/20, lab/21, or netmgmt/12** on BT8-gateway.
Doing so before Phase 3 would put a duplicate `10.97.11.1` (etc.) on
the mesh fabric and cause ARP collisions with `thebeyond`. Phase 3
handles those VLANs as a separate per-VLAN cutover (one transaction
removes the IP from `thebeyond` and adds it on BT8-gateway).

### Hardware staging (two-device topology during the window)

This runbook is designed to introduce a **second** BT8 (the spare)
without disrupting the **legacy BT8** that is currently the office
gateway. The two devices coexist on the network for the entire
duration of Phases 1–5; the cutover in §6 is purely a cable swap,
not a flash event.

Topology during §1–§5:

- **Legacy BT8** stays exactly where it is, doing exactly what it
  does today: terminating L3 for the homelab VLANs it currently
  owns, plugged into the homelab L2 switch trunk, carrying homelab
  traffic to the internet via its existing path. **Do not touch it.**
- **Spare BT8** is in the office on a one-port patch cable to the
  operator's laptop (LuCI on `192.168.1.1`). After mesh comes up
  (§5.A–§5.D) it joins the batman fabric as a peer of `BT8-bridge`,
  but it is **not** plugged into the homelab L2 switch yet, so no
  homelab frames cross through it.
- **`thebeyond`** is unchanged from its post-Phase-1 deployed state.

Why this is ARP-clean while both devices coexist on overlapping
fabrics: legacy BT8 does not speak batman-adv, so it is not a
participant in the mesh fabric the spare joins. The two devices share
the homelab L2 switch's broadcast domain, but **only on VLANs where
the spare has no IP** — which in Phase 2 is every VLAN legacy BT8
owns (10/11/20/21/100). The spare's only L3 IPs (`10.97.50.1` APP and
`10.255.255.2` transit) live on subnets legacy BT8 doesn't touch. No
duplicate-IP conflict possible.

(The user's existing VLAN 30 mesh-bridge workaround for reaching
thebeyond also continues to work through this window — it's
independent of either BT8's gateway role.)

### What stays working throughout this runbook

This is the reachability assurance: nothing in the existing homelab
should break while BT8-gateway is brought up.

- **Existing management/trusted/lab/DMZ/network traffic** continues
  flowing through legacy BT8 → existing wired/mesh path → thebeyond
  → internet, exactly as it does today. The new BT8-gateway is sitting
  on a laptop cable doing config; it has no path to homelab clients
  until the §6 cable swap.
- **APP traffic** has no production clients yet (Phase 5 of the plan
  moves services into APP). The L3 you stand up here is infrastructure
  for that future work.
- **Operator's existing thebeyond access** (the VLAN 30 mesh-bridge
  workaround, if you're using it) continues to work — neither BT8 in
  Phase 2 disturbs that path.
- **Operator laptop access to the spare BT8**: the laptop stays on
  the spare's `<MGMT>` wired port in `br-lan` (default
  `192.168.1.0/24`) throughout the runbook. That's how LuCI and SSH
  access to the spare work during config. The `lan` fw4 zone is
  preserved for this reason (the full-cutover variant of this
  runbook would delete it; we don't).

### Stopping points

There are two safe pauses inside this runbook:

1. **End of §5.F** — mesh joined + all VLAN sub-devices created, but
   zero L3 commitments. Device can sit indefinitely; no production
   impact. (§5.F.5 has an explicit STOP block with the transit
   prerequisites.)
2. **End of §5.L** — all bridges built, transit working, no firewall
   changes yet. A natural checkpoint with a sysupgrade backup.

If you have to abandon the window, abort at one of these. After §5.M
(firewall changes), abort is harder and the troubleshooting appendix
should be consulted before pulling the plug.

---

## Window structure

Approximate duration: **2–4 hours** of active work on the spare BT8,
spread across as many sittings as you want (legacy BT8 is still
running, so there is no clock pressure). Plus a few-seconds cable
swap at §6.

This runbook is **not a maintenance window** in the conventional
sense:

- Phases 1–5 happen on the spare BT8 at the operator's desk; the
  homelab keeps using legacy BT8 unchanged. You can stop and resume
  freely.
- Phase 6 is a single ~5–10 second cable swap. The rollback (plug
  legacy back in) is the same motion in reverse.

The discrete phases inside this runbook (numbered locally; do not
confuse with the plan's phase numbers):

1. **Phase 1** — Build the image via Firmware Selector. Do this
   pre-window; takes ~5 minutes once you have the recipe.
2. **Phase 2** — Flash the **spare** BT8 from stock to OpenWrt 25.12.
   Takes ~10 minutes plus first-boot. Legacy BT8 untouched.
3. **Phase 3** — First-boot LuCI setup (root password, SSH) on the
   spare.
4. **Phase 4** — Post-flash SSH verification (must pass before any
   UCI on the spare).
5. **Phase 5** — LuCI step-by-step configuration on the spare.
   Discrete Save & Apply checkpoints; restricted to the APP + transit
   L3 commitments.
6. **Phase 6** — Cable swap: legacy BT8 unplugged from the homelab L2
   switch trunk, spare (now BT8-gateway) plugged in. Verification on
   homelab side. Rollback by reversing the swap.

You can pause between any two checkpoints to think, eat, sleep, or
abort. The §5.M (firewall zones) → §5.O (DHCP enabled) span is
locally the riskiest stretch on the spare _for the spare's own
config_, but it has **no homelab impact** either way — the worst
outcome is "spare BT8 is misconfigured, reflash it tomorrow".

After this runbook completes, BT8-gateway is in production for APP +
transit only. **Phase 3 (per-VLAN cutover for
management/trusted/lab/netmgmt)** is a separate later window with its
own runbook.

---

## Phase 1 — Build the image (Firmware Selector)

**Do this pre-window.** Browser-based; takes ~5 minutes.

### 1.1 Navigate to Firmware Selector

Open <https://firmware-selector.openwrt.org/> in a browser.

### 1.2 Select the BT8 device profile

In the search box, type the BT8 model name. Pick the matching profile
from the dropdown. **Verify** the listed `target` is `mediatek/filogic`
(this is the MT7988A SoC family).

If multiple profiles appear (e.g., variants), choose the one matching
your exact hardware revision. The one you want will list `mt7988`
somewhere in its identifiers.

### 1.3 Pin the OpenWrt version

In the **Version** dropdown, select **`25.12.3`** or later in the
`25.12.x` series. Do **not** use:

- 24.10.x (older release; not the planned BT8 baseline)
- 25.12.0 / 25.12.1 (MediaTek 2.4 GHz latency regression, hot-fixed in
  25.12.2; 25.12.3 has further filogic fixes)
- `SNAPSHOT` (unreleased; do not use for production)

### 1.4 Customize the package list

Click **Customize installed packages**. Select the entire default
package list and **replace** it with the unified BT8 recipe below.
Whitespace-separated, single line is fine; the order doesn't matter.

```
-wpad-basic-mbedtls -ppp -ppp-mod-pppoe kmod-batman-adv batctl-full wpad-mesh-openssl luci luci-app-firewall luci-proto-batman-adv htop tcpdump
```

What this does:

- `-wpad-basic-mbedtls`, `-ppp`, `-ppp-mod-pppoe` — explicitly remove
  defaults that conflict with our needs (basic wpad does not support
  mesh; PPPoE is not used because `thebeyond` does WAN).
- `kmod-batman-adv`, `batctl-full` — batman-adv kernel + full
  userspace (the basic `batctl` build is missing `batctl o/n/s`
  subcommands you'll need for verification).
- `wpad-mesh-openssl` — the one wpad variant that supports both
  802.11s mesh and AP modes.
- `luci`, `luci-app-firewall`, `luci-proto-batman-adv` — LuCI web UI
  - the firewall and batman-adv protocol handlers in LuCI.
- `htop`, `tcpdump` — diagnostics. Worth their flash cost during the
  manual phases.

**Do NOT remove** `firewall4`, `nftables`, `dnsmasq`, or
`odhcpd-ipv6only` from the default list. The BT8-gateway role
**uses** all of these. (The BT8-bridge and mesh-AP roles disable them
via init.d, but BT8-gateway leaves them on.)

### 1.5 Build and download

Click **Request Build** (or equivalent). When the build completes,
download:

- `*-squashfs-factory.bin` — for first install from stock firmware.
- `*-squashfs-sysupgrade.bin` — for re-flashing later (preserves
  config) and as a rollback artifact.

Save both files to your laptop. Verify the SHA256 against the value
shown in Firmware Selector (the page lists hashes; compute locally
with `sha256sum *.bin`).

### 1.6 Save the package list

Save the exact package recipe you used (the line from §1.4) into your
operator secret store with a label like `bt8-image-2026-05-XX`. This
lets you reproduce the exact same image later.

---

## Phase 2 — Flash the device

### 2.1 Power on, connect

Plug your laptop's ethernet into a BT8 LAN port (not WAN). Power on
the BT8. Wait ~60 seconds for it to boot.

The BT8 ships with stock firmware (vendor's web UI on `192.168.1.1`
typically). Open that page in a browser; follow the vendor's
**firmware upgrade / sysupgrade** workflow to flash the
`*-factory.bin` from §1.5.

(If the BT8 is already on OpenWrt — e.g., a previous owner flashed it
— skip to LuCI sysupgrade in §2.3 instead.)

### 2.2 Wait for first boot

After flash, the device reboots. Wait ~90 seconds. The new OpenWrt
image will come up with default settings: `192.168.1.1` on `br-lan`,
no root password set.

### 2.3 (Alternative) Re-flash from existing OpenWrt via LuCI

If you ever need to re-flash later (e.g., to recover from a botched
config and start fresh): **System → Backup / Flash Firmware → Flash
new firmware image**. **UNCHECK** "Keep settings" to wipe; check it to
preserve. Upload `*-sysupgrade.bin` and click Flash.

---

## Phase 3 — First-boot LuCI setup

Browse to <http://192.168.1.1>. You should land on the LuCI login page
(or, on first boot, a password-set prompt).

### 3.1 Set the root password

LuCI may force you to set a root password before it lets you in. Use
the value from your secret store. **Do not skip this step.**

If LuCI does not force it: go to **System → Administration →
Router Password**, set it, **Save**.

### 3.2 Add your SSH key

**System → Administration → SSH-Keys** tab. Paste your laptop's
public key (the one from `~/.ssh/id_*.pub`). **Save**.

You can now `ssh root@192.168.1.1` from your laptop. Open a second
terminal with this SSH session — you'll need it for the F.2
verification block in Phase 4 and for batctl/ip diagnostics later.

### 3.3 Set hostname and timezone

**System → System → General Settings**:

- **Hostname**: `bt8gateway`
- **Timezone**: `UTC`

Click **Save & Apply** (this is your first one — should be painless).

---

## Phase 4 — Post-flash SSH verification

**Do not proceed past this phase if any check fails.** A failed check
means the image recipe is wrong; rebuild with corrected packages and
re-flash before continuing. Do **not** try to patch with `apk add` —
mixing feed packages with firmware-shipped packages will brick the
device sooner or later.

In your SSH terminal (`ssh root@192.168.1.1`):

```sh
# 1. Confirm the right wpad variant.
apk list -I 2>/dev/null | grep -E '^wpad' \
  || opkg list-installed | grep -E '^wpad'
# Expect a line containing 'wpad-mesh-openssl'.
# FAIL if you see 'wpad-basic-mbedtls' or 'wpad-mini' instead.

# 2. Confirm batman-adv loads cleanly.
modprobe batman-adv && lsmod | grep batman_adv
# Expect 'batman_adv' module present in lsmod output.

# 3. Confirm batctl is the full build.
batctl --help 2>&1 | grep -E '^[[:space:]]*(originators|neighbors)'
# Expect 'originators' and 'neighbors' subcommands listed.

# 4. Confirm gateway-role services are present.
[ -f /etc/init.d/firewall ] && echo "OK firewall" || echo "FAIL firewall"
[ -x /usr/sbin/dnsmasq ]    && echo "OK dnsmasq"  || echo "FAIL dnsmasq"
[ -x /usr/sbin/odhcpd ]     && echo "OK odhcpd"   || echo "FAIL odhcpd"
# All three should report OK.
```

If anything fails, **stop**. Rebuild the image with the corrected
recipe (Phase 1) and re-flash (Phase 2). Then re-run this phase.

### 4.1 Identify your wired uplink port name

Still in SSH:

```sh
ip -br link
```

Note the names of the LAN ports. On MT7988A devices these are
typically `lan1`, `lan2`, `lan3`, `lan4`, possibly `wan` or `eth1`
for the SFP+ / 10G port. **Pick one wired port for the homelab
trunk** — call it `<TRUNK>` for the rest of this document. The plan
assumes `lan1`. Adjust per your hardware if the names differ.

**Pick a different port for laptop access** — call it `<MGMT>`. The
plan implicitly assumes you keep your laptop on a port that stays in
`br-lan` (the default LuCI access bridge) until the very end. Use
`lan2` or `lan3`. **Do not put your laptop on `<TRUNK>`** — that port
gets reconfigured in Phase 5 and you'll lose access.

---

## Phase 5 — LuCI step-by-step configuration

Each numbered step ends in a Save & Apply. Verify the listed checks
before moving to the next step. **Do not batch steps**.

### 5.A — Configure the mesh radio

**Network → Wireless**.

You'll see two or three radios (`radio0` = 2.4 GHz, `radio1` = 5 GHz,
`radio2` = 6 GHz if present). Identify the 5 GHz radio (`radio1`) —
this hosts the mesh.

Click **Add** on `radio1`:

- **General Setup** tab:
  - **Mode**: `802.11s`
  - **Mesh ID**: `home-mesh`
  - **Network**: type `mesh` and pick "Create:" — this creates a
    new network entry that we'll wire up in §5.B.
  - **Force CCMP encryption**: leave default (mesh forces SAE below).
- **Wireless Security** tab:
  - **Encryption**: `WPA3-SAE`
  - **Key**: paste `MESH_PSK` from your secret store
- **Advanced Settings** tab:
  - **Mesh Forwarding**: **disable / set to `0`** (batman-adv handles
    forwarding; native 802.11s forwarding would conflict)

Also confirm **Channel** matches the channel BT8-bridge is using
(check on BT8-bridge: `ssh root@10.91.10.4 'iw dev mesh0 info'` →
`channel` line). All mesh peers must be on the same channel.

**Save** the wifi-iface; **Save & Apply** the page.

After apply: `radio1` should show the mesh interface as up but
unconnected (because `bat0` doesn't exist yet). That's fine.

### 5.B — Configure the `mesh` interface as batman-adv hardif

**Network → Interfaces → Devices** tab:

The new `mesh` interface should have appeared. Click **Edit** on it.

- **General device options**:
  - **MTU**: `1536` (batman-adv overhead headroom)

**Save** the device.

Now switch back to the **Interfaces** tab. Click **Edit** on the
`mesh` interface:

- **General Settings** tab:
  - **Protocol**: `Batman-adv hardif`
  - **Master**: `bat0` (you'll create this in §5.C; LuCI may not
    autocomplete it yet — type it literally and save)

**Save & Apply.**

### 5.C — Create the `bat0` interface

Still in **Network → Interfaces**, click **Add new interface...**

- **Name**: `bat0`
- **Protocol**: `Batman-adv`
- Leave device empty for now (LuCI may pre-create a `bat0` device on
  apply; we'll attach sub-devices to it in 5.E onward)

Click **Create interface**. On the resulting form:

- **Advanced Settings** tab:
  - **Routing algorithm**: `BATMAN_V`
  - **Gateway mode**: `off` (this device routes via thebeyond, not
    via batman-adv's gateway selection)

**Save & Apply.**

### 5.D — Verify mesh connectivity (CHECKPOINT)

In SSH:

```sh
ip -br link | grep -E 'bat0|mesh'   # both should show UP/UNKNOWN
batctl if                            # mesh0 listed as a hardif
batctl n                             # neighbours table populated;
                                     # BT8-bridge should appear within 30s
batctl o                             # originator table covers BT8-bridge,
                                     # thebeyond, and any other mesh members
```

**If `batctl n` is empty after 60 seconds:**

- Verify mesh PSK matches (typo is the most common cause).
- Verify mesh ID matches exactly (`home-mesh`).
- Verify channel matches.
- Verify BT8-bridge's mesh radio is up: `ssh root@10.91.10.4 'iw dev mesh0 info'`.
- Verify line-of-sight / RSSI: `iw dev mesh0 station dump` should
  show entries with `signal` ≥ -75 dBm for usable throughput.

Do **not** proceed past this checkpoint until `batctl n` lists
BT8-bridge.

### 5.E — Create `bat0.<vid>` VLAN sub-devices

You need a `bat0.<vid>` for **every VLAN this device touches in Phase
2** — both L3-terminating ones and L2-only passthrough ones. Without
`bat0.<vid>`, frames for that VLAN have nowhere to land on this device.

In Phase 2 the only **L3-terminating** VLANs on BT8-gateway are
`app/50` and `transit/255`. The other VLANs listed below
(`network/10`, hostile zones `30/31/40/41`, `dmz/100`) get
**L2-passthrough** bridges in §5.J so frames can cross between the
mesh fabric and the wired homelab L2 switch, but BT8-gateway holds no
IP, no zone, no DHCP on them — L3 stays on `thebeyond`.

**Deliberately omitted in Phase 2**: VLANs `11` (management), `12`
(netmgmt), `20` (trusted/HOME), `21` (lab). Phase 1 left their L3 on
`thebeyond` and routes them via the mesh. Adding their `bat0.<vid>`
sub-devices on BT8-gateway prematurely would tempt the operator to
also add the L3 bridges, which would collide with `thebeyond`'s
addresses on the same fabric. Phase 3 introduces these four VLANs as a
single coordinated cutover (sub-device → passthrough bridge → L3 IP →
zone → DHCP, with the matching IP removed from `thebeyond` in the
same window).

**Network → Interfaces → Devices** tab → **Add device configuration...**

For each VLAN in the table below, create one device:

- **Type**: `VLAN (802.1q)`
- **Base device**: `bat0`
- **VLAN ID**: as listed
- (LuCI auto-fills the device name as `bat0.<vid>`)

| VLAN ID | Name       | Purpose                                                 |
| ------- | ---------- | ------------------------------------------------------- |
| 10      | `bat0.10`  | network — L2 passthrough                                |
| 30      | `bat0.30`  | untrusted (GUEST) — L2 passthrough                      |
| 31      | `bat0.31`  | adu — L2 passthrough                                    |
| 40      | `bat0.40`  | iot — L2 passthrough                                    |
| 41      | `bat0.41`  | game — L2 passthrough                                   |
| 50      | `bat0.50`  | app — **L3 terminated here** (the new APP gateway)      |
| 100     | `bat0.100` | dmz — L2 passthrough                                    |
| 255     | `bat0.255` | transit — **L3 terminated here** (gateway to thebeyond) |

**Save** each one. After all are added, **Save & Apply** the page.

You can do these in batches of 3–4 if you prefer fewer apply cycles.
This step is purely additive — risk is low.

### 5.F — Create `<TRUNK>.<vid>` VLAN sub-devices on the wired trunk port

These will eventually be members of the per-VLAN bridges so the
homelab L2 switch (or any directly-connected gear) can talk to each
VLAN. We create them now but only attach them to bridges in §5.G–5.H.

**Network → Interfaces → Devices** tab → **Add device configuration...**

For each VLAN in the table below, create one device:

- **Type**: `VLAN (802.1q)`
- **Base device**: `<TRUNK>` (e.g., `lan1`)
- **VLAN ID**: as listed

Create one trunk sub-device per L2-passthrough or L3-terminated VLAN
from §5.E (same VLAN set; VLANs 11/12/20/21 stay out of Phase 2):

| VLAN ID | Name          |
| ------- | ------------- |
| 10      | `<TRUNK>.10`  |
| 30      | `<TRUNK>.30`  |
| 31      | `<TRUNK>.31`  |
| 40      | `<TRUNK>.40`  |
| 41      | `<TRUNK>.41`  |
| 50      | `<TRUNK>.50`  |
| 100     | `<TRUNK>.100` |
| 255     | `<TRUNK>.255` |

**IMPORTANT before save:** `<TRUNK>` is currently a member of
`br-lan` (the default bridge). Adding 802.1q sub-devices on top of it
is fine — they coexist with the underlying port being in `br-lan`.
But you cannot put `<TRUNK>` itself into another bridge while it's
still in `br-lan`. We work around this by using `<TRUNK>.<vid>` (the
VLAN sub-device, not the parent port) as the bridge member. This
means **untagged frames on `<TRUNK>` continue to land in `br-lan`**;
that's fine because the homelab L2 switch will only send tagged
frames once you cut over.

**Save & Apply.**

### 5.F.5 — STOP: safe pause point before any L3 commitment

> **You are at the first safe stopping point.** Everything before this
> step is purely additive: the device has joined the mesh, has VLAN
> sub-devices on both sides (mesh and wired trunk), and has zero IPs,
> zero bridges, zero firewall zones. It can sit in this state
> indefinitely with no impact on production — neither side is bridged
> together yet, so no homelab traffic crosses through it.
>
> The next step (§5.G) adopts `default via 10.255.255.1` as
> BT8-gateway's only upstream route. If `thebeyond`'s transit
> termination isn't actually up, this device loses its way out at
> exactly the moment you click Save & Apply, and your only management
> path is the laptop cable.
>
> **Re-verify the transit prerequisite before proceeding:**
>
> 1. From the operator laptop (or any host on `network`/10 that you
>    can reach), confirm `ping 10.255.255.1` succeeds. This must be
>    answered by `thebeyond`'s `brTRANSIT` interface — Phase 1.4 stood
>    it up. If it doesn't answer, **stop here**: Phase 1 isn't
>    actually deployed, and continuing will create a broken default
>    route on this device.
> 2. Confirm `batctl n` on this device still lists BT8-bridge (no mesh
>    flap since §5.D).
> 3. Confirm the homelab L2 switch trunks VLAN 255 toward this device
>    if you intend to plug `<TRUNK>` in after §5.L. (You can defer
>    this verification until immediately before §6 cabling; mesh-side
>    transit works regardless.)
>
> If any of the above fails, do **not** proceed to §5.G. Either fix
> Phase 1 deployment first, or abort the window (the device is inert
> at this checkpoint — nothing to roll back).

### 5.G — Create the transit bridge and interface (HIGHEST PRIORITY VLAN)

Configure transit first because everything else (default route, DNS,
NTP) flows through it. If you only get one VLAN working today, this
is the one.

**Network → Interfaces → Devices** tab → **Add device configuration...**

- **Type**: `Bridge device`
- **Device name**: `br-v255`
- **Bridge ports**: select `bat0.255` AND `<TRUNK>.255`
- (Leave bridge VLAN filtering OFF — we are not using bridge-vlan-filtering;
  one bridge per VLAN is the model here.)

**Save** the device.

**Network → Interfaces → Add new interface...**

- **Name**: `transit`
- **Protocol**: `Static address`
- **Device**: `br-v255`

Click **Create interface**.

On the **General Settings** tab:

- **IPv4 address**: `10.255.255.2`
- **IPv4 netmask**: `255.255.255.252` (this is `/30`)
- **IPv4 gateway**: `10.255.255.1`
- **Use custom DNS servers**: `10.255.255.1`

On the **Advanced Settings** tab:

- **Use default gateway**: leave checked

Now also add IPv6. On **General Settings**:

- **IPv6 assignment length**: leave **disabled** (no `ip6assign`;
  ULA-only baseline, no PD)
- **IPv6 address**: `fdc6:55f2:0a5e:ffff::2/64`
- **IPv6 gateway**: `fdc6:55f2:0a5e:ffff::1`

**Save & Apply.**

### 5.H — CHECKPOINT: verify transit reachability

In SSH:

```sh
ip -4 addr show dev br-v255       # should show 10.255.255.2/30
ip -6 addr show dev br-v255       # should show fdc6:55f2:0a5e:ffff::2/64
ip route                         # should show 'default via 10.255.255.1 dev br-v255'
ip -6 route                      # should show default via fdc6:55f2:0a5e:ffff::1

ping -c 3 10.255.255.1           # thebeyond's transit IP — MUST work
ping6 -c 3 fdc6:55f2:0a5e:ffff::1  # IPv6 transit — should work
ping -c 3 1.1.1.1                # internet via thebeyond NAT — MUST work
ping -c 3 10.91.10.10            # phantasma DNS resolver via transit
```

**If `ping 10.255.255.1` fails:**

- Run `batctl o` and confirm `thebeyond` appears in the originator
  table. If not, the wired link from BT8-bridge to thebeyond is
  broken — investigate on BT8-bridge (`batctl n` should list
  thebeyond as a wired-hardif neighbour).
- Run `tcpdump -ni br-v255 'icmp'` while pinging from another
  terminal — confirm packets are leaving on `br-v255`.
- Run `tcpdump -ni bat0.255 'icmp'` — confirm batman is carrying them.
- On thebeyond: `tcpdump -ni brTRANSIT 'icmp'` — confirm they arrive.
- If they arrive on thebeyond but no reply: thebeyond's `transit`
  zone may not have the input rule for ICMP echo. Check
  `nft list table inet filter`.

**Do not proceed past this checkpoint until transit works in both
directions.** Everything below assumes you have `10.255.255.1`
reachable from BT8-gateway.

### 5.I — Create the `network`/10 L2-passthrough bridge (no L3 here)

`network` is L2-only on this device — frames cross from mesh to
trunk-port without being terminated. BT8-gateway holds **no L3** on
network/10 (hermetic east/west isolation).

**Network → Interfaces → Devices** tab → **Add device configuration...**

- **Type**: `Bridge device`
- **Device name**: `br-v10`
- **Bridge ports**: `bat0.10` AND `<TRUNK>.10`

**Save** the device.

**Network → Interfaces → Add new interface...**

- **Name**: `v10`
- **Protocol**: `Unmanaged`
- **Device**: `br-v10`

Click **Create interface**, then **Save & Apply**.

(Repeating: this interface has **no IP** on this device. The L3 for
`network` lives on `thebeyond`.)

### 5.J — Create the APP/50 L3-terminating bridge and interface

APP is the **only** new L3 zone BT8-gateway adopts in Phase 2 (besides
transit, which §5.G handled). All other L3 commitments —
`management/11`, `netmgmt/12`, `trusted/20`, `lab/21` — are deferred
to Phase 3 to avoid a duplicate-IP collision on the mesh fabric while
`thebeyond` still owns those subnets.

Follow the pattern from §5.G (bridge device + interface with static
IP). Single VLAN; single Save & Apply.

**`app` / VLAN 50:**

- **Network → Interfaces → Devices** tab → **Add device configuration...**
  - **Type**: `Bridge device`
  - **Device name**: `br-v50`
  - **Bridge ports**: `bat0.50` AND `<TRUNK>.50`
- **Save** the device.
- **Network → Interfaces → Add new interface...**
  - **Name**: `app`
  - **Protocol**: `Static address`
  - **Device**: `br-v50`
  - **IPv4 address**: `10.97.50.1` / `255.255.255.0`
  - **IPv6 address**: `fdc6:55f2:0a5e:1032::1/64`
  - **No IPv4 gateway** (the default route lives on transit)
- **Save & Apply.**

Verify:

```sh
ip -4 addr show dev br-v50    # shows 10.97.50.1/24
ip -6 addr show dev br-v50    # shows fdc6:55f2:0a5e:1032::1/64
```

> **Phase 3 will add four more bridges to this section** (`br-v11`,
> `br-v12`, `br-v20`, `br-v21`) — each created with its IPs in the
> same window that strips the matching IP off `thebeyond`. Do not
> stand them up now.

### 5.K — Create the L2-passthrough VLAN bridges (no L3 here)

For the hostile-zone family + DMZ. All gateway L3 lives on
`thebeyond`; BT8-gateway is just a fan-out point. Each gets a bridge
and an `Unmanaged` interface (no IP).

Repeat the pattern from §5.I:

- `br-v100` (DMZ): members `bat0.100`, `<TRUNK>.100` → interface `v100`, Unmanaged
- `br-v30` (GUEST/untrusted): members `bat0.30`, `<TRUNK>.30` → interface `guest`, Unmanaged
- `br-v31` (adu): members `bat0.31`, `<TRUNK>.31` → interface `adu`, Unmanaged
- `br-v40` (iot): members `bat0.40`, `<TRUNK>.40` → interface `iot`, Unmanaged
- `br-v41` (game): members `bat0.41`, `<TRUNK>.41` → interface `game`, Unmanaged

You can configure these in 1–2 Save & Apply batches; risk is low
(each is purely additive, with no IP to clash).

### 5.L — CHECKPOINT: snapshot before firewall

This is the **second safe stopping point** in the runbook. All
bridges are built, transit works, but no firewall zones exist yet
(default fw4 is still permissive). The device can be safely cabled
into the homelab L2 switch from this point on — passthrough VLANs
will reach `thebeyond` through the mesh, APP/transit will route on
this box. If you must pause for hours/overnight, this is the place.

In SSH:

```sh
ip -br link    | sort                # all br-v*, bat0.*, <TRUNK>.* devices present
ip -br addr -4 | grep 'br-v'         # exactly 2 entries with an IPv4:
                                     #   br-v50  10.97.50.1/24    (APP)
                                     #   br-v255 10.255.255.2/30  (transit)
                                     # All other br-v* show no IPv4 (L2 passthrough)
ip -br addr -6 | grep 'br-v'         # same two with their fdc6:55f2:0a5e:* /64s
ping -c 2 10.255.255.1               # transit still works
ping -c 2 1.1.1.1                    # internet still works
nft list ruleset | head -50          # default fw4 ruleset present
                                     # (still permissive — no zones added yet)
```

Expected bridges at this checkpoint (Phase 2 scope):

| Bridge    | VLAN | L3?              | Members                      |
| --------- | ---- | ---------------- | ---------------------------- |
| `br-lan`  | —    | mgmt only        | `lan2` (laptop), default LAN |
| `br-v10`  | 10   | L2 passthrough   | `bat0.10`, `<TRUNK>.10`      |
| `br-v30`  | 30   | L2 passthrough   | `bat0.30`, `<TRUNK>.30`      |
| `br-v31`  | 31   | L2 passthrough   | `bat0.31`, `<TRUNK>.31`      |
| `br-v40`  | 40   | L2 passthrough   | `bat0.40`, `<TRUNK>.40`      |
| `br-v41`  | 41   | L2 passthrough   | `bat0.41`, `<TRUNK>.41`      |
| `br-v50`  | 50   | **L3 — APP**     | `bat0.50`, `<TRUNK>.50`      |
| `br-v100` | 100  | L2 passthrough   | `bat0.100`, `<TRUNK>.100`    |
| `br-v255` | 255  | **L3 — transit** | `bat0.255`, `<TRUNK>.255`    |

Not present (deliberately, deferred to Phase 3): `br-v11`, `br-v12`,
`br-v20`, `br-v21`.

This is a good place to **back up** before touching the firewall.
Run on BT8-gateway:

```sh
sysupgrade -b /tmp/pre-firewall-backup.tar.gz
```

Then on your laptop: `scp root@192.168.1.1:/tmp/pre-firewall-backup.tar.gz ~/`.
This gives you a one-command rollback point if firewall config goes
sideways: re-flash the image, restore this backup, you're back to
the post-§5.K state.

### 5.M — Configure firewall zones

**This is the highest-risk single step.** A bad fw4 zone can
silently drop your transit traffic and you'll lose internet
reachability without warning.

**Phase 2 zone summary (sanity-check list):**

| Zone      | Interface                | Input    | Output   | Forward  | Purpose                                                               |
| --------- | ------------------------ | -------- | -------- | -------- | --------------------------------------------------------------------- |
| `lan`     | `lan` (default `br-lan`) | `accept` | `accept` | `reject` | **KEEP** — operator laptop cable; LuCI/SSH surface during the runbook |
| `transit` | `transit`                | `reject` | `accept` | `reject` | Uplink to `thebeyond` (point-to-point /30)                            |
| `app`     | `app`                    | `reject` | `accept` | `reject` | New APP zone (10.97.50.0/24)                                          |

That is the entire set for Phase 2. No `management`, `netmgmt`,
`trusted`, `lab`, or hostile-zone fw4 zones — those L3 surfaces don't
exist on this box yet (Phase 3 adds the first four; the hostile zones
stay L2-passthrough only on this device forever, with fw enforcement
on `thebeyond`).

**Network → Firewall → General Settings** tab:

- **Drop invalid packets**: enabled
- **Input**: `reject`
- **Output**: `accept`
- **Forward**: `reject`

Now switch to the **Zones** section. Delete the default `wan` zone
(no `wan` interface on this device). **Keep the default `lan` zone**
— it covers `br-lan` which is your laptop cable and the only
management surface during this runbook. Click the trash icon on
`wan` only.

**Wait — do NOT save & apply yet.** Add the new zones first.

**Add the `transit` zone:**

- **Name**: `transit`
- **Input**: `reject`
- **Output**: `accept`
- **Forward**: `reject`
- **Masquerading**: **off** (NAT lives on thebeyond, not here)
- **MSS clamping**: off
- **Covered networks**: `transit`

**Add the `app` zone:**

- **Name**: `app`
- **Input**: `reject`, **Output**: `accept`, **Forward**: `reject`
- **Covered networks**: `app`

**Confirm the existing `lan` zone is unchanged:**

- **Name**: `lan` (default)
- **Input**: `accept`, **Output**: `accept`, **Forward**: `reject`
- **Covered networks**: `lan` (the default `br-lan` interface)
- Do **not** delete this. You lose laptop LuCI/SSH if you do.

(Note: no fw4 zone for `network`/10, `guest`/30, `adu`/31, `iot`/40,
`game`/41, or `dmz`/100 — these are L2-only on this device, no L3
interface to bind. Their fw enforcement runs on thebeyond.
`management`/11, `netmgmt`/12, `trusted`/20, `lab`/21 are deferred
to Phase 3 with their bridges.)

### 5.M.1 — Add inter-zone forwardings

Still on **Network → Firewall**, scroll to **Inter-Zone Forwarding**.

Phase 2 needs exactly one forward (plus the `lan→*` defaults from the
preserved `lan` zone, which we don't touch):

| Source | Destination | Purpose                                  |
| ------ | ----------- | ---------------------------------------- |
| `app`  | `transit`   | APP clients → internet/DMZ via thebeyond |

That's it. The full forwarding mesh
(`trusted→*`, `lab→*`, `management→*`, `netmgmt→transit`) gets added
in Phase 3 when those source zones actually exist on this device.

Now **Save & Apply** the whole firewall page.

### 5.M.2 — Add explicit traffic rules

**Network → Firewall → Traffic Rules** tab.

You should see existing default rules (Allow-DHCP-Renew,
Allow-Ping-WAN, etc.). Most will reference `wan` which no longer
exists; either delete them or leave them — they will be inert without
a `wan` zone. Cleanest is to **delete every default rule** and add
back only what we explicitly need.

The `lan` zone defaults already provide laptop → device input
(SSH/LuCI/DHCP); the rules below cover only the new APP and transit
surfaces.

**Add: Allow DNS and DHCP to BT8-gateway from APP and transit**

- **Name**: `Allow-DNS-DHCP`
- **Protocol**: `TCP UDP`
- **Source zone**: `app` (add a second rule for `transit` if you want
  thebeyond to be able to hit dnsmasq on this box — usually not
  needed, defer if unsure)
- **Destination zone**: `Device (input)`
- **Destination port**: `53 67 547`
- **Action**: `accept`
- (Optional rate-limit) **Extra arguments**: `--limit 100/sec`

**Add: Allow ICMP echo from APP and transit (diagnostics)**

- **Name**: `Allow-ICMP-app`
- **Protocol**: `ICMP`
- **Source zone**: `app`
- **Destination zone**: `Device (input)`
- **Action**: `accept`

- **Name**: `Allow-ICMP-transit`
- **Protocol**: `ICMP`
- **Source zone**: `transit`
- **Destination zone**: `Device (input)`
- **Action**: `accept` (this is what makes
  `ping 10.255.255.2` from `thebeyond` work and lets the §5.M.3
  smoke test pass)

**Save & Apply.**

> **Deferred to Phase 3** (do **not** add now): `Allow-SSH-mgmt`,
> `Allow-LuCI-mgmt`, `app-basel-ACME`. They reference the
> `management` source zone (Allow-SSH-mgmt / Allow-LuCI-mgmt) or
> resolve into the `management` destination subnet (app-basel-ACME) —
> neither destination interface nor source zone exists on this box in
> Phase 2. Add them in the Phase 3 window alongside the
> `management/11` bridge.

### 5.M.3 — CHECKPOINT: firewall sanity

```sh
nft list ruleset | wc -l            # should be much larger than the §5.L snapshot
ping -c 2 10.255.255.1              # MUST still work (BT8-gw → thebeyond ICMP echo
                                    # from the transit zone — gate-checked by
                                    # thebeyond's transit input rules, not here)
ping -c 2 1.1.1.1                   # MUST still work (NAT on thebeyond)
```

If `ping 10.255.255.1` fails after firewall apply: the most likely
culprit is the `transit` zone or the `Allow-ICMP` rule. Re-check the
zones list under Network → Firewall and confirm:

- `transit` zone exists with `transit` interface bound
- `Allow-ICMP` rule exists with **Source: Any zone**

If you can't fix it via LuCI in 5 minutes, restore from backup:

```sh
sysupgrade -r /tmp/pre-firewall-backup.tar.gz   # restores config, reboots
```

(or use the backup you saved on your laptop in §5.L if /tmp got wiped)

### 5.N — Configure DNS resolver and dnsmasq base

**Network → DHCP and DNS → General Settings** tab:

- **DNS forwardings**: `10.255.255.1` (thebeyond's local kresd, which
  forwards to phantasma at `10.91.10.10`)
- **Local server**: `/internal/`
- **Local domain**: `internal`
- **Authoritative**: checked
- **Domain required**: checked
- **Bogus NX domain override**: leave default
- **Localise queries**: checked
- **Rebind protection**: checked

**Resolv and Hosts Files** tab:

- **Use `/etc/resolv.conf`**: leave default
- **Ignore resolve file**: checked (we want only the explicit upstream)

**Save & Apply.**

Test:

```sh
nslookup example.com 127.0.0.1     # should return an answer via 10.255.255.1
nslookup phantasma.internal 127.0.0.1   # should resolve via thebeyond's kresd
```

### 5.O — Configure DHCP servers per VLAN

Phase 2 stands up DHCP for **APP/50 only**. `home`/20 and `lab`/21
DHCP servers are deferred to Phase 3 (they'd require their L3 bridges
to exist on this device, which is exactly what Phase 3 adds).
`management` and `netmgmt` never get DHCP on this device (static IPs
from the registry).

**Network → DHCP and DNS → DHCP** tab → for each entry, click on the
matching interface row (or **Add** if not present):

**`app` (VLAN 50):**

- **Interface**: `app`
- **Ignore interface**: unchecked
- **Start**: `100`
- **Limit**: `100`
- **Lease time**: `12h`
- **IPv6 settings** tab:
  - **Router Advertisement-Service**: `server mode`
  - **DHCPv6-Service**: `server mode`
  - **NDP-Proxy**: `disabled`
  - **DHCPv6-Mode**: `stateful + stateless`
  - **Always announce default router**: checked
  - **Announced DNS servers**: `fdc6:55f2:0a5e:ffff::1`
  - **RA Flags**: `managed-config`, `other-config`

**Save & Apply.**

That's the only DHCP server BT8-gateway runs in Phase 2. Phase 3 will
add `home` (trusted/20) and `lab` (lab/21) pools when their bridges
land — the operator on each downstream client will see no DHCP change
during Phase 2 because their lease is still served by `thebeyond` over
the mesh.

### 5.O.1 — Static reservations

For each host listed in the registry under
`lib/common/data/network.nix` that lives in a BT8-gateway-owned zone,
add a static lease so the IP is stable.

**Network → DHCP and DNS → Static Leases** tab → **Add**:

- **Hostname**, **MAC address**, **IPv4-address**

(Refer to your printed registry data — the hosts and IPs are
authoritative there.)

This step is tedious but mostly inert — wrong static leases just
mean a host doesn't get its expected IP, easy to fix later.

### 5.P — NTP

**System → System → Time Synchronization** tab:

- **Enable NTP client**: checked
- **Provide NTP server**: checked (so downstream clients can use BT8-gw as NTP source)
- **NTP server candidates**: `10.255.255.1` (thebeyond's transit IP)

Remove the default upstream `*.openwrt.pool.ntp.org` entries — BT8-gateway
should sync only via thebeyond, not directly to the internet (see plan §
"Routing model": BT8-gateway never reaches into the high-trust plane).

**Save & Apply.**

```sh
chronyc sources    # or 'ntpq -p' depending on which NTP daemon ships
                   # — should show 10.255.255.1 as the upstream
```

### 5.Q — Client AP SSIDs (optional, skip if not bringing up wifi today)

Each SSID is bound to a per-VLAN bridge; batman + 802.1q does the
rest. If you're keeping the office wifi on existing E8450 / mesh-AP
hardware for now, skip this step.

**Phase 2 SSID scope:** only the L2-passthrough zones whose bridges
exist on this device — **GUEST/30, IOT/40, GAME/41** (and ADU/31 if
desired). **HOME wifi is deferred to Phase 3** because it requires
`br-v20` (trusted/20), which isn't built until then. Keep HOME on the
existing E8450 / mesh-AP hardware until Phase 3.

**Network → Wireless → Add** on `radio1` (5 GHz) or `radio0` (2.4 GHz):

For GUEST wifi (example pattern):

- **General Setup** tab:
  - **Mode**: `Access Point`
  - **ESSID**: your GUEST SSID
  - **Network**: `guest` (the L2-passthrough interface bridged into
    `br-v30`; thebeyond is the L3 gateway, frames cross via mesh)
- **Wireless Security** tab:
  - **Encryption**: `WPA3-SAE` or `WPA2-PSK/WPA3-SAE Mixed Mode`
  - **Key**: GUEST PSK from secret store

Repeat for IOT (network `iot`, bridge `br-v40`), GAME (network
`game`, bridge `br-v41`), and optionally ADU (network `adu`, bridge
`br-v31`).

**Important:** for the L2-passthrough zones, the `Network` field
binds to the **interface name** (`guest`, `iot`, `game`, `adu`) —
these interfaces have `proto 'none'` and are bridged into the matching
`br-v30` / `br-v40` / `br-v41` / `br-v31`. The SSID injects client
frames directly into the bridge tagged with the right VID; batman
delivers them to thebeyond, which is the L3 gateway for those zones.

**Save & Apply** after each SSID.

### 5.R — Final config save

Now that everything is up, take a config backup:

```sh
sysupgrade -b /tmp/post-config-backup.tar.gz
```

Copy to laptop:

```sh
scp root@192.168.1.1:/tmp/post-config-backup.tar.gz ~/
```

Save with a name like `bt8gateway-2026-05-XX-post-config.tar.gz` in
your secret store. This is your "known good" snapshot for any future
revert.

---

## Phase 6 — Cable swap (legacy BT8 → BT8-gateway)

> **What this section is.** A few-seconds physical cable change:
> the homelab L2 switch's trunk uplink moves from legacy BT8 to the
> newly configured BT8-gateway. Everything BT8-gateway needs to serve
> traffic is already configured (§5); legacy BT8 is replaced wholesale,
> not partially. **Plan Phase 1 must already be deployed on
> `thebeyond`** — that is what makes the swap safe (thebeyond is
> ready to serve L3 for all the VLANs legacy BT8 was carrying, over
> the mesh path that BT8-gateway now provides). See [the prerequisite
> gate in the plan](../wip/dual-gateway-app-vlan-plan.md#phase-2--manual-proof-bt8-bridge-and-bt8-gateway)
> for the full set of checks.

### 6.1 Pre-swap verification — L2 switch trunk config matches BT8-gateway

Before unplugging anything, confirm the homelab L2 switch is
configured to trunk the **exact VLAN set** that BT8-gateway expects
on `<TRUNK>`. On the L2 switch, the uplink port that _will_ go to
BT8-gateway should trunk:

- **VLAN 50** (APP) — new; BT8-gateway terminates it.
- **VLAN 10, 30, 31, 40, 41, 100** — passthrough; BT8-gateway's
  bridges relay these to thebeyond over the mesh.
- **VLAN 11, 20, 21** — passthrough at the _L2 switch level_,
  exactly as today (the switch keeps trunking them to whatever it
  trunks them to today; in Phase 2 those frames go to thebeyond via
  the mesh path through BT8-gateway, the same fabric Phase 3 will
  later L3-terminate on BT8-gateway).
- **VLAN 255** (transit) — usually mesh-only, but trunking on the
  wire is harmless and is a useful fallback if the mesh degrades.

You do **not** need to change which physical port on the L2 switch
the uplink lives on — if legacy BT8 is plugged into port N today,
BT8-gateway will be plugged into port N tomorrow with the same
trunk config. The L2 switch's UCI/config does not need to change at
all for the swap itself (some plan items add netmgmt/12 trunking
later, but that's not part of this swap).

**If the L2 switch isn't already trunking the full VLAN set to the
legacy-BT8 uplink port**, fix that now (it's a no-op to do
proactively — frames not consumed are dropped, no traffic impact)
and verify with `bridge vlan show` or LuCI's bridge view.

### 6.2 The swap

Have the new BT8-gateway powered up and verified at end of §5.R
(post-config sysupgrade backup in hand). Then:

1. Pull the laptop patch cable from BT8-gateway's `<MGMT>` port.
   (Optional — you can leave it for emergency LuCI access during the
   swap, but it's not needed for the swap itself.)
2. **Unplug** the homelab trunk cable from legacy BT8's uplink port.
3. **Plug** that same cable into BT8-gateway's `<TRUNK>` port.

Total elapsed time on a clean swap: ~5–10 seconds. The homelab
notices a brief link flap on whatever VLAN it was actively using and
recovers as soon as the BT8-gateway-side bridges learn MACs (one or
two ARP round-trips). Connections survive: the homelab → thebeyond
path is now physically wire → BT8-gateway L2-passthrough bridge →
mesh → thebeyond, which is a shorter (and stronger) version of the
path legacy BT8 was providing.

### 6.3 Post-swap verification — passthrough regression check

This is the most important check: **nothing should be broken**. From
a host on a passthrough VLAN that worked before the swap (a NAS on
`network`/10, anything on `management`/11, `trusted`/20):

```sh
ip route                          # unchanged from pre-swap
                                  # (still defaults via thebeyond's IP on this VLAN)
ping <thebeyond's IP on this VLAN>  # routes via wire → BT8-gateway → mesh → thebeyond
ping 1.1.1.1                      # internet via thebeyond NAT
nslookup example.com              # DNS via thebeyond's kresd
```

All four must work. If any fails, **roll back immediately** (§6.5)
and diagnose offline.

### 6.4 Post-swap verification — APP (the new path)

If you have a test client for APP (a laptop on a VLAN 50 access port,
or any host you can temporarily re-VLAN onto 50):

```sh
ip route                          # default via 10.97.50.1
ping 10.97.50.1                   # BT8-gateway local APP gateway
ping 10.255.255.1                 # thebeyond via transit
ping 1.1.1.1                      # internet (via thebeyond NAT)
ping 10.91.10.10                  # phantasma via transit → thebeyond
nslookup example.com              # DNS via thebeyond's kresd
```

If APP has no client to test with yet (likely — Phase 5 of the plan
moves services into APP), this verification can be deferred.

Also confirm the cross-gateway route is live on thebeyond:

```sh
# From BT8-gateway:
ssh root@10.255.255.1 ip route | grep 10.97.50
# Expect: 10.97.50.0/24 via 10.255.255.2 dev brTRANSIT
```

If the route is missing, plan Phase 1 wasn't deployed — but at this
point you're already cabled over, so most likely you got past the
prerequisite-gate check at the top of this runbook and the route is
in fact present.

### 6.5 Rollback (if anything fails)

The swap is fully reversible in the time it takes to swap the cable
back:

1. **Unplug** the trunk cable from BT8-gateway's `<TRUNK>` port.
2. **Plug** it back into legacy BT8's uplink port (the original).
3. Legacy BT8 resumes its old role with no config changes — it was
   never modified during this runbook.

Total rollback time: ~5–10 seconds. After rollback, leave BT8-gateway
powered up and on its laptop cable; diagnose what failed offline,
fix the spare, and re-attempt the swap when ready. Nothing about this
process is one-way until you decommission legacy BT8 in §7.4.

### 6.6 Verify the wifi SSIDs you brought up in §5.Q (if any)

If you stood up GUEST/IOT/GAME/ADU SSIDs on this device:

- Connect a client to each SSID in turn.
- Confirm DHCP lease arrived from `thebeyond` (the L3 gateway).
- Browse a website / `ping 1.1.1.1`.

HOME wifi was deferred — keep it on the existing hardware.

### 6.7 External security scan (deferred)

Phase 2 doesn't change `thebeyond`'s WAN edge (still the same gateway
as before). The Phase 0b.13 external scan covered that surface. No
new scan is required for Phase 2 closeout.

---

## Phase 7 — Cleanup (only after full verification)

These steps remove the legacy `lan`/`br-lan` access path. **Do them
last**, after you've confirmed full connectivity in §6.

### 7.1 Decide on management access path

You have two options going forward:

- **A:** Keep `br-lan` and `<MGMT>` port active for emergency console
  access. Cost: one wired port permanently dedicated; minor security
  surface (LuCI on `192.168.1.1` with only laptop physical access).
- **B:** Remove `lan` interface entirely; future LuCI access goes
  through `management` VLAN via the homelab L2 switch.

**Recommended: A** for the duration of the manual phases; B once
Phase 4 codifies BT8-gateway in the Image Builder and image-built
lockdown is in place (Phase 4.5).

### 7.2 If choosing B, decommission default LAN

**Network → Interfaces** → click **Remove** on the `lan` interface.
**Save & Apply.** You will lose `192.168.1.1` access at this point;
make sure your laptop is reachable on the management VLAN through
the homelab switch first.

**Network → Interfaces → Devices** → remove the `br-lan` bridge
device. **Save & Apply.**

### 7.3 Lock down LuCI/SSH source (Phase 4.5 of the plan, deferred)

Per plan Phase 4.5: restrict SSH (22) and LuCI (80/443) to a
management-host allowlist via `inputRules` on the `management` zone.
**Do not do this during today's window** — it requires a separate
test cycle and a known operator workstation IP. Track for a
follow-up.

### 7.4 Decommission the legacy BT8

After §6 has been stable for **at least 24 hours** (a full day of
real homelab traffic crossing the new fabric without operator
intervention), retire the legacy BT8. Until then, leave it powered
off but in place — it is your fastest fallback if a latent issue
surfaces.

Three reasonable end-states for the legacy device:

- **A. Wipe to factory** — `firstboot && reboot` over serial (or
  factory-reset button) and shelve. Simplest; gives you a clean
  spare for unrelated future projects.
- **B. Reflash with the unified BT8 image and re-role as an office
  mesh AP** — per [runbook C of the
  plan](../wip/dual-gateway-app-vlan-plan.md#c-manual-setup-bt8-as-office-side-dumb-ap-mesh-resident).
  This is the preferred path: it adds capacity/redundancy to the
  office-side mesh that BT8-gateway depends on for transit, and the
  mesh AP role uses the same unified image so there is no extra
  build step. Configure it with the same `MESH_PSK` and
  `home-mesh` mesh ID, disable dnsmasq/odhcpd/firewall, give it a
  single mgmt IP on `network`/10. Cabling: a single wired uplink to
  the L2 switch trunk (any management VLAN you've trunked) plus the
  802.11s mesh radio.
- **C. Keep as a hot spare for BT8-gateway** — leave the post-§5.R
  sysupgrade backup of BT8-gateway on your laptop with a one-page
  "how to reflash legacy → BT8-gateway role" pointer. Cost: one
  device shelved doing nothing. Benefit: zero-time disaster recovery
  if BT8-gateway dies later.

Whichever you choose, **document what you did** in the operator's
notes so a future-you (or someone else) knows the legacy device's
current state and how to reverse it.

---

## Phase 8 — Plan Phase 3 cutover (per-VLAN gateway move)

This phase completes the dual-gateway design: INFRA/11, HOME/20, and
LAB/21 L3 termination moves from `thebeyond` to BT8-gateway. The
bridges (`br-v11`, `br-v20`, `br-v21`) already exist on BT8-gateway as
L2-passthrough from Phase 2 (per as-built UCI, with both `bat0.<vid>`
and `br0.<vid>` as members). This phase **promotes them from
L2-passthrough to L3-terminated** by adding bridge IPs, fw4 zone
bindings, dnsmasq DHCPv4, and odhcpd DHCPv6/RA — all via a per-VLAN
scripted SSH transaction that races thebeyond's IP-removal against
BT8-gateway's IP-addition to keep the no-`.1` window sub-second.

**Why a separate window from Phase 2:** Phase 2 only proved the
dual-gateway routing/firewall model for APP/50 (one greenfield VLAN).
This phase migrates production VLANs with live DHCP leases and
existing client traffic. The blast radius is larger, the rollback path
is per-VLAN (not all-or-nothing), and notification of household /
collaborators is appropriate (HOME briefly loses inter-VLAN routing
during cutover).

**Prerequisite:** `router6.routes` deployed on `thebeyond` with the
cross-gateway statics already in place (`10.97.0.0/16 via 10.255.255.2`
and `fdc6:55f2:0a5e:1000::/52 via fdc6:55f2:0a5e:ffff::2`). Verify
with `ip route show 10.97.0.0/16` on `thebeyond` before opening this
window. Without those routes, return-path traffic to the migrated
VLANs has nowhere to go from `thebeyond` once its connected /24s on
brINFRA/brHOME/brLAB are removed in §8.4.

NETMGMT/12 is **not** migrated by this phase. The homelab L2 switch
folding into the flake is a separate follow-up plan; until that lands,
NETMGMT has no consumers and there's nothing to cut over.

---

### 8.0 Pre-cutover sanity checks (do BEFORE pre-staging)

From operator workstation:

```sh
# router6.routes deployed on thebeyond
ssh root@thebeyond.internal 'ip route show 10.97.0.0/16'
# expect: 10.97.0.0/16 via 10.255.255.2 dev brTRANSIT proto static
ssh root@thebeyond.internal 'ip -6 route show fdc6:55f2:0a5e:1000::/52'
# expect: ... via fdc6:55f2:0a5e:ffff::2 dev brTRANSIT proto static

# BT8-gateway reachable on both transit AF
ssh root@thebeyond.internal 'ping -c 3 10.255.255.2'
ssh root@thebeyond.internal 'ping -c 3 fdc6:55f2:0a5e:ffff::2'

# BT8-gateway's L2-passthrough bridges for 11/20/21 are up
ssh root@10.255.255.2 'ip link show br-v11 br-v20 br-v21 | grep state'
# expect: each shows "state UP" (or "state UNKNOWN" with NO-CARRIER absent)

# Confirm batman sees BT8-bridge (mesh path to thebeyond intact)
ssh root@10.255.255.2 'batctl n'
# expect: BT8-bridge's MAC visible with a small LastSeen

# No existing IPs on the L2-passthrough bridges (would indicate prior
# half-applied cutover)
ssh root@10.255.255.2 'ip -4 addr show br-v11 br-v20 br-v21 | grep -E "10\.97\.(11|20|21)\.1"'
# expect: no output
```

If any check fails, **stop**. Don't pre-stage further until resolved.

---

### 8.1 Pre-stage BT8-gateway via LuCI (non-disruptive, do anytime ahead of window)

All §8.1 changes are inert — the bindings exist but the bound
interfaces are still `proto 'none'` (no IP), so the new zones are
empty and the staged DHCP blocks are `ignored`. Each subsection is
one **Save & Apply** in LuCI (90-second auto-rollback timer protects
against losing your management session), safe to do incrementally
across multiple sittings.

Connect to LuCI from a host that can reach BT8-gateway over
transit/network — e.g. `https://10.255.255.2` from thebeyond, or
direct via the lan port from operator workstation if cabled.

#### 8.1.1 Normalize iot/game interface device refs

**Network → Interfaces**.

For `iot`:

- Click **Edit**.
- **Device**: change from `bat0.40` to `br-v40`.
- **Save**.

For `game`:

- Click **Edit**.
- **Device**: change from `bat0.41` to `br-v41`.
- **Save**.

**Save & Apply** (whole page). No traffic disruption — the `br-v40`/
`br-v41` bridges already exist with `bat0.4x` + `br0.4x` as members
(same as today); this just relabels which device the interface block
references.

(Pure cosmetic / Nix-consistency win, but easier to do now than during
or after the cutover.)

#### 8.1.2 Add fw4 zones for management / trusted / lab

**Network → Firewall → Zones** tab.

This mirrors §5.M where `app` and `transit` were created. Same form,
same defaults (reject input/forward, accept output, no masquerade).

**Add `management`:**

- **Name**: `management`
- **Input**: `reject`
- **Output**: `accept`
- **Forward**: `reject`
- **Masquerading**: off
- **MSS clamping**: off
- **Covered networks**: `mgmt`

**Add `trusted`:**

- **Name**: `trusted`
- **Input**: `reject`
- **Output**: `accept`
- **Forward**: `reject`
- **Masquerading**: off
- **Covered networks**: `home`

**Add `lab`:**

- **Name**: `lab`
- **Input**: `reject`
- **Output**: `accept`
- **Forward**: `reject`
- **Masquerading**: off
- **Covered networks**: `lab`

**Save & Apply.** The zones now exist but their covered interfaces
are still `proto 'none'` — fw4 treats the zones as having no active
interfaces until §8.3 promotes the interface protos.

If LuCI's rollback timer triggers (you lost management because of a
mis-typed zone name), reconnect and try again with corrected values.
This is the value of using LuCI for staging: the timer rescues you
automatically.

#### 8.1.3 Add inter-zone forwarding mesh

**Network → Firewall → Inter-Zone Forwarding** (or the **Zones** tab
in newer LuCI, which has inline forwarding selectors per zone).

Add each forwarding pair below. Per the plan's zone table:

| Source       | Destination  | Purpose                                                                      |
| ------------ | ------------ | ---------------------------------------------------------------------------- |
| `trusted`    | `app`        | HOME → APP-resident services (Jellyfin, Forgejo, etc., post-Phase-5)         |
| `trusted`    | `management` | HOME → mgmt-zone services (Prometheus UI, etc.)                              |
| `trusted`    | `lab`        | HOME → lab (edith, etc.)                                                     |
| `trusted`    | `transit`    | HOME → internet via transit→thebeyond (catch-all; thebeyond's transit gates) |
| `lab`        | `management` | Lab → mgmt services                                                          |
| `lab`        | `transit`    | Lab → internet / DMZ via transit                                             |
| `management` | `trusted`    | Mgmt → HOME (admin reach)                                                    |
| `management` | `app`        | Mgmt → APP (Prometheus scrape, etc.)                                         |
| `management` | `transit`    | Mgmt → internet / DMZ via transit                                            |

Notably absent: `management → lab`. Mgmt initiates into lab only via
specific input rules added per-host, not blanket-forwarded.

**Save & Apply.**

#### 8.1.4 Add per-zone input rules

**Network → Firewall → Traffic Rules** tab. Mirrors the §5.M.2 rules
that exist for `app` today.

**Add: Allow-DNS-DHCP-mgmt**

- **Name**: `Allow-DNS-DHCP-mgmt`
- **Protocol**: `TCP UDP`
- **Source zone**: `management`
- **Destination zone**: `Device (input)`
- **Destination port**: `53 67 547`
- **Action**: `accept`

**Add: Allow-ICMP-mgmt**

- **Name**: `Allow-ICMP-mgmt`
- **Protocol**: `ICMP`
- **Source zone**: `management`
- **Destination zone**: `Device (input)`
- **Action**: `accept`

**Add: Allow-DNS-DHCP-trusted** (same shape, source `trusted`).
**Add: Allow-ICMP-trusted** (same shape, source `trusted`).
**Add: Allow-DNS-DHCP-lab** (same shape, source `lab`).
**Add: Allow-ICMP-lab** (same shape, source `lab`).

**Save & Apply.**

#### 8.1.5 Stage DHCP / RA blocks per VLAN (ignored)

**Network → DHCP and DNS → DHCP** is the global dnsmasq config; the
per-interface DHCP blocks live in **Network → Interfaces → \<iface\>
→ DHCP Server** tab.

For each of `mgmt`, `home`, `lab`:

- **Network → Interfaces** → click **Edit** on the interface.
- Go to the **DHCP Server** tab.
- **Ignore interface**: **check this box** (this sets `option ignore '1'`).
  Without this, dnsmasq will try to start serving the moment the
  interface gets a static IP — which is what we want during cutover
  but not during pre-staging.
- **Setup DHCP Server**: keep enabled (the box still needs to exist).
- **Start**: `100`
- **Limit**: `150`
- **Lease time**: `12h`

Switch to the **IPv6 Settings** tab on the same interface. **Two
separate dropdowns** at the top of this tab control different pieces
of the v6 stack — easy to confuse. **Both must be set to "server
mode"**:

- **Router Advertisement-Service**: `server mode` → emits the UCI
  `option ra 'server'` line. **Without this, odhcpd sends no RAs at
  all.** Clients get an address via DHCPv6 but no default router,
  no DNS via RA, no on-link prefix advertisement. The symptom is "v4
  works, v6 address present, but ping to anything off-link fails with
  no default route in `netsh interface ipv6 show route`." This field
  sits immediately next to "DHCPv6-Service" in the LuCI form, and the
  two labels are easy to read as one bundled setting — double-check
  that both dropdowns are explicitly set.
- **DHCPv6-Service**: `server mode` → UCI `option dhcpv6 'server'`.
  Stateful DHCPv6 address assignment.
- **NDP-Proxy**: `disabled`
- **DHCPv6-Mode**: `stateful` (advertises `M=1, O=1` flags)
- **Always announce default router**: **checked** (sets `ra_default '1'`).
  **Required for ULA-only deployments.** Without it, odhcpd's default
  behavior is to only advertise a default router when a public (GUA)
  prefix is delegated to the interface. BT8-gateway has no GUA — only
  ULA — so the default-route advertisement is suppressed.
- **Router Lifetime**: `1800` (sets `ra_lifetime '1800'`). Explicitly
  setting this protects against odhcpd's auto-compute returning 0 when
  no GUA prefix exists. Without it, even `ra_default '1'` can produce
  an RA with `router lifetime 0s`.
- **Announced DNS servers**: `fdc6:55f2:0a5e:ffff::1` (thebeyond's
  transit-side address, where kresd is bound)
- **Announced DNS domains**: `internal`

**Verify before moving on** — the most common failure mode at this
stage is "I configured most of these but missed `ra=server`":

```sh
ssh root@10.255.255.2 'uci show dhcp.<iface> | grep -E "^dhcp\.<iface>\.(ra|dhcpv6|ra_default|ra_lifetime)"'
# expect ALL of:
#   dhcp.<iface>.ra='server'
#   dhcp.<iface>.dhcpv6='server'
#   dhcp.<iface>.ra_default='1'
#   dhcp.<iface>.ra_lifetime='1800'
```

**Save** (the per-interface form). Repeat for the other two interfaces.

Then **Save & Apply** at the top.

Verify the blocks are present but ignored:

```sh
ssh root@10.255.255.2 'uci show dhcp | grep -E "ignore|interface=.(mgmt|home|lab)."'
# expect three sets of: dhcp.<iface>.interface='<iface>' and dhcp.<iface>.ignore='1'
```

#### 8.1.6 Set hostname

**System → System** tab.

- **Hostname**: `bt8gw`

**Save & Apply.**

#### 8.1.7 Snapshot post-staging state

**System → Backup / Flash Firmware** → **Generate archive** →
download. Save with a meaningful name:

```sh
mv ~/Downloads/backup-OpenWrt-*.tar.gz \
   ~/operator-backups/bt8gw-pre-phase3-$(date +%Y%m%d).tar.gz
```

This is your rollback target if a cutover goes wrong and you need to
get BT8-gateway back to "Phase 2 + inert Phase 3 staging" state. Note
this is a snapshot of the _staged but inert_ state, not a working
post-cutover state.

If you have to restore from this backup mid-window, use **System →
Backup / Flash Firmware → Restore backup** in LuCI (preserves
configuration; doesn't re-flash firmware).

---

### 8.2 Stage thebeyond cleanup commit

In the dotfiles repo on the operator workstation, prepare (but do not
deploy) a commit that removes the migrated zones from thebeyond:

In `lib/common/data/network.nix`, no change needed — management/11,
trusted/20, lab/21 stay in the registry (BT8-gateway needs them).

In `hosts/thebeyond/router.nix`:

- Remove the `management`, `trusted`, `lab` entries from
  `subnetBindings`. This drops the corresponding `mkVlanBridge`
  invocations and so removes brINFRA/brHOME/brLAB and their `.1`
  addresses.
- Remove the `management`, `trusted`, `lab` zone definitions from
  `router6.zones`.
- Remove any forwardRules in _other_ zones that named the dropped
  zones as destinations (otherwise eval fails — assertions catch this).
  Cross-reference: `transit.forwardRules.dmz` source-restricted by
  `lab` subnet is fine (string IP, not a zone name); same for the
  `forwardRules.untrusted` rule restricted to the trusted subnet.
- Drop the `management.hosts` cross-zone forwardRules that lived on
  the management zone (the TEMP rule for management → creil, plus
  tharbad → DMZ scrape) — those flows now originate from a
  BT8-gateway-terminated zone and traverse transit, so the rules need
  to land in `transit.forwardRules.dmz` (or be source-restricted by
  IP if the rule already exists there).

Run `nix flake check` locally to catch the assertion failures before
the window starts. Commit on a branch but **do not deploy**. The
commit is staged so step §8.4 is just `deploy-rs`.

---

### 8.3 Cutover window

Open a maintenance window. Expected duration: 15–30 minutes including
verification. Per-VLAN cutover takes seconds; the window length is
dominated by verification between VLANs.

**Why this section is SSH-only, not LuCI:** the cutover transaction
spans two devices (thebeyond + BT8-gateway) and needs sub-second
atomicity to keep the no-`.1` window short. LuCI's Save & Apply
cycle (form submission + commit + service reload + rollback timer) is
seconds per step on a single device, with no cross-device
coordination — by the time you click "Apply" on BT8-gateway, thebeyond
has been without `.1` for tens of seconds and clients have started
ARPing for a nonexistent host. SSH with `&&`-chained commands keeps
the whole transaction under a second on each device. The rollback
safety you get from LuCI in §8.1 doesn't apply here because the
cutover is a _coordinated change across two devices_, not a single
config edit — neither device's individual rollback would unwind the
other side.

If you need to abort mid-cutover, follow §8.7.

#### 8.3.1 Window kickoff checklist

- [ ] §8.0 sanity checks still pass.
- [ ] §8.1 pre-staging complete; `pre-phase3-cutover-backup.tar.gz`
      saved to operator workstation.
- [ ] §8.2 thebeyond cleanup commit prepared on operator workstation;
      `nix flake check` passes locally.
- [ ] Operator notified household / collaborators of brief HOME
      disconnect (~5 seconds while DHCP renews).
- [ ] Operator workstation has working v4 + v6 path to both
      `thebeyond` (via current HOME terminated there) AND BT8-gateway
      (via mesh through HOME → bat0 → BT8-gateway). The workstation
      is the only host that needs to maintain reachability throughout;
      everything else converges via DHCP/RA.
- [ ] Operator workstation has `~/.ssh/config` aliases set for
      `thebeyond.internal` and `10.255.255.2` (BT8-gateway via
      transit — current path).

#### 8.3.2 Cutover script template

Per-VLAN script. Substitute the values from §8.3.3 for each VLAN.
Run from operator workstation. Each `&&` ensures the next step only
fires if the previous succeeded; a mid-script failure stops the
transaction before duplicate-IP state.

```sh
# Variables to substitute per VLAN:
#   VLAN          — VLAN ID (11 / 20 / 21)
#   VLAN_HEX      — bt8gw-group prefix + vlan hex (100b / 1014 / 1015)
#   BRTHE         — thebeyond's bridge name (brINFRA / brHOME / brLAB)
#   BRBT8         — BT8-gateway's bridge name (br-v11 / br-v20 / br-v21)
#   KEA_UNIT      — Kea systemd unit name for this VLAN (check first)

VLAN=21
VLAN_HEX=1015
BRTHE=brLAB
BRBT8=br-v21
KEA_UNIT=kea-dhcp4-server@${VLAN}.service   # verify before running

# Single SSH transaction. Each step <100ms; total no-.1 window <1s.
ssh root@thebeyond.internal "systemctl stop ${KEA_UNIT}" && \
ssh root@thebeyond.internal "ip addr del 10.97.${VLAN}.1/24 dev ${BRTHE}" && \
ssh root@thebeyond.internal "ip -6 addr del fdc6:55f2:0a5e:${VLAN_HEX}::1/64 dev ${BRTHE}" && \
ssh root@10.255.255.2 "ip addr add 10.97.${VLAN}.1/24 dev ${BRBT8}" && \
ssh root@10.255.255.2 "ip -6 addr add fdc6:55f2:0a5e:${VLAN_HEX}::1/64 dev ${BRBT8}" && \
ssh root@10.255.255.2 "uci set network.${BRBT8/br-v/v}.proto=static && \
                       uci set network.${BRBT8/br-v/v}.ipaddr=10.97.${VLAN}.1 && \
                       uci set network.${BRBT8/br-v/v}.netmask=255.255.255.0 && \
                       uci add_list network.${BRBT8/br-v/v}.ip6addr=fdc6:55f2:0a5e:${VLAN_HEX}::1/64 && \
                       uci commit network" && \
ssh root@10.255.255.2 "uci set dhcp.${BRBT8/br-v/v}=dhcp && uci del dhcp.${BRBT8/br-v/v}.ignore && uci commit dhcp" && \
ssh root@10.255.255.2 "/etc/init.d/dnsmasq reload && /etc/init.d/odhcpd reload" && \
ssh root@10.255.255.2 "arping -c 3 -U -I ${BRBT8} 10.97.${VLAN}.1"
```

**Important notes on the script:**

- The `${BRBT8/br-v/v}` shell expansion strips `br-v` → leaves `v11`/
  `v20`/`v21` — but the actual UCI interface names from §8.1 are
  `mgmt`/`home`/`lab` (not v11/v20/v21). **Substitute the UCI
  interface name manually** in the `uci set ...` lines:
  - VLAN 11: `network.mgmt` / `dhcp.mgmt`
  - VLAN 20: `network.home` / `dhcp.home`
  - VLAN 21: `network.lab` / `dhcp.lab`
- `arping -c 3 -U` uses busybox's gratuitous-ARP flag (`-U`), not
  iputils's (`-A`). Don't try to "fix" this by installing
  `iputils-arping` mid-stream — it'd force an image rebuild + reflash.
- The `Kea systemd unit name` may differ — verify by running
  `ssh root@thebeyond.internal 'systemctl list-units "kea*"'` before
  the window. If thebeyond uses a single `kea-dhcp4-server.service`
  for all VLANs, stopping it kills DHCP for _every_ still-on-thebeyond
  VLAN simultaneously. Cross-check with `hosts/thebeyond/router.nix`'s
  Kea configuration before assuming per-VLAN units exist.

#### 8.3.3 Per-VLAN cutover order

Recommended order: lowest impact first. Verify each VLAN with §8.3.4
before proceeding to the next.

**Order A — lab/21 first (recommended):**

| Variable  | Value    |
| --------- | -------- |
| VLAN      | `21`     |
| VLAN_HEX  | `1015`   |
| BRTHE     | `brLAB`  |
| BRBT8     | `br-v21` |
| UCI iface | `lab`    |

Impact: edith (dev environment, calvard Incus container) and bose /
ravennue (Arr stack microVMs on liberl) re-DHCP onto BT8-gateway.
Brief disconnect, no household-visible impact.

**Order B — trusted/20 (HOME) second:**

| Variable  | Value    |
| --------- | -------- |
| VLAN      | `20`     |
| VLAN_HEX  | `1014`   |
| BRTHE     | `brHOME` |
| BRBT8     | `br-v20` |
| UCI iface | `home`   |

Impact: operator workstation re-DHCPs. If the workstation has a
static IP / persistent lease, no re-DHCP needed and disconnect is
sub-second. azoth (Raspberry Pi for HA / MQTT) re-DHCPs.

**Order C — management/11 last:**

| Variable  | Value     |
| --------- | --------- |
| VLAN      | `11`      |
| VLAN_HEX  | `100b`    |
| BRTHE     | `brINFRA` |
| BRBT8     | `br-v11`  |
| UCI iface | `mgmt`    |

Impact: highest. calvard, erebonia, liberl, basel, messeldam,
tharbad, roer all re-DHCP. Brief gap in Prometheus scraping
(tharbad), Forgejo access (creil from management), etc. — all
self-resolving as DHCP renews and the new gateway answers.

#### 8.3.4 Per-VLAN verification (run between cutovers)

After each VLAN's script completes, verify before moving to the next:

```sh
# On BT8-gateway: confirm bridge has the new IP
ssh root@10.255.255.2 "ip -4 addr show ${BRBT8} | grep ${VLAN}.1"
ssh root@10.255.255.2 "ip -6 addr show ${BRBT8} | grep ${VLAN_HEX}::1"

# On thebeyond: confirm bridge no longer has the IP
ssh root@thebeyond.internal "ip -4 addr show ${BRTHE} | grep -c ${VLAN}.1"
# expect: 0

# From operator workstation: confirm new gateway answers
ping -c 3 10.97.${VLAN}.1
ping6 -c 3 fdc6:55f2:0a5e:${VLAN_HEX}::1

# Existing client on the migrated VLAN reaches internet
# (pick a known host; e.g., calvard for VLAN 11)
ssh root@calvard 'curl -s -o /dev/null -w "%{http_code}\n" https://1.1.1.1'
# expect: 200

# DNS resolution still works
ssh root@calvard 'dig +short example.com'
# expect: a non-empty A record
```

If verification fails: see §8.7 rollback. **Do not proceed to next
VLAN until current one verifies.**

---

### 8.4 Post-cutover: deploy thebeyond cleanup

With all three VLANs cut over and verified, deploy the staged commit
from §8.2:

```sh
# In the dotfiles repo on operator workstation
git switch <phase3-cleanup-branch>
nix run github:serokell/deploy-rs -- .#thebeyond
```

`deploy-rs` magic_rollback verifies SSH stays up post-activation. The
deploy is functionally inert from a client perspective: it removes
inactive bridge declarations from `thebeyond`'s NixOS config, which
makes the brINFRA/brHOME/brLAB devices go away cleanly. systemd-networkd
tears down the now-undeclared interfaces. No client traffic flows
through those bridges anymore (the gateway moved in §8.3), so removal
is silent.

After deploy, verify the routes still look right on thebeyond:

```sh
ssh root@thebeyond.internal 'ip route show 10.97.0.0/16'
# still: 10.97.0.0/16 via 10.255.255.2 dev brTRANSIT proto static
ssh root@thebeyond.internal 'ip route show 10.97.11.0/24'
# expected: no output — the connected /24 is gone, so /16 catches it
ssh root@thebeyond.internal 'ip route get 10.97.11.5'
# expect: via 10.255.255.2 dev brTRANSIT (was: dev brINFRA, connected)
```

The connected /24s for 11/20/21 are gone; the /16 catches everything
in BT8-gateway's address space.

Repeat verification from §8.3.4 after this deploy — clients should
still reach internet and DNS. If anything regresses, the suspect is
either (a) a fw4 rule on BT8-gateway that didn't cover an allow case,
or (b) a routing case that depended on thebeyond's connected /24 in a
way that wasn't covered by transit forwarding.

---

### 8.5 Post-cutover housekeeping (low priority)

- Persist UCI changes on BT8-gateway. The `ip addr add` in §8.3.2 is
  transient; the script's `uci set network.<iface>.proto=static` and
  `uci commit network` in the same transaction make it durable. Verify
  with `ssh root@10.255.255.2 'cat /etc/config/network | grep -A4 "interface .mgmt."'`
  — should show `proto 'static'` + `ipaddr` + `ip6addr`.
- Take a post-cutover BT8-gateway sysupgrade snapshot for the new
  baseline:

  ```sh
  ssh root@10.255.255.2 'sysupgrade -b /tmp/post-phase3-cutover-backup.tar.gz'
  scp root@10.255.255.2:/tmp/post-phase3-cutover-backup.tar.gz \
      ~/operator-backups/bt8gw-post-phase3-$(date +%Y%m%d).tar.gz
  ```

- Update DNS / monitoring dashboards that hard-coded `10.97.11.1` or
  similar as a Prometheus target. None should — those are gateway IPs,
  not service IPs, and shouldn't be scraped. Worth a search anyway.

---

### 8.6 External security scan (required)

Re-run Runbook E external scan from off-network. Phase 3 is the
largest single change to `thebeyond`'s zone topology in the plan, and
fw4 rule re-derivation on BT8-gateway is a plausible regression vector
(open `input` or `forward` somewhere that shouldn't be).

Save scan artifacts with date + deploy SHA for compliance trail.

---

### 8.7 Per-VLAN rollback (if mid-window failure)

If §8.3.4 verification for the current VLAN fails, reverse the
cutover for that VLAN only. Other (successfully cut over) VLANs stay
on BT8-gateway.

```sh
# Reverse the IP move
ssh root@10.255.255.2 "uci set dhcp.<iface>.ignore=1 && uci commit dhcp" && \
ssh root@10.255.255.2 "ip addr del 10.97.${VLAN}.1/24 dev ${BRBT8}" && \
ssh root@10.255.255.2 "ip -6 addr del fdc6:55f2:0a5e:${VLAN_HEX}::1/64 dev ${BRBT8}" && \
ssh root@10.255.255.2 "uci set network.<iface>.proto=none && \
                       uci del network.<iface>.ipaddr && \
                       uci del network.<iface>.netmask && \
                       uci del network.<iface>.ip6addr && \
                       uci commit network && \
                       /etc/init.d/network reload" && \
ssh root@thebeyond.internal "ip addr add 10.97.${VLAN}.1/24 dev ${BRTHE}" && \
ssh root@thebeyond.internal "ip -6 addr add fdc6:55f2:0a5e:${VLAN_HEX}::1/64 dev ${BRTHE}" && \
ssh root@thebeyond.internal "systemctl start ${KEA_UNIT}" && \
ssh root@thebeyond.internal "arping -c 3 -A -I ${BRTHE} 10.97.${VLAN}.1"
```

Note: thebeyond's arping is iputils → `-A`, not BT8-gateway's
busybox → `-U`.

Then **abort the window** — do not proceed to the next VLAN. Diagnose
what failed before re-attempting. Common causes:

- fw4 rule gap on BT8-gateway (zone or forwarding missed in §8.1).
  Symptom: client gets DHCP, can ping gateway, can't reach anything
  else. Check `nft list ruleset` on BT8-gateway for the dropped flow.
- Kea unit naming wrong (didn't actually stop on thebeyond). Symptom:
  client gets a lease from both gateways, intermittent breakage.
  Stop Kea fully on thebeyond and confirm before re-cutover.
- Cross-gateway route missing (`router6.routes` deploy didn't land or
  was rolled back). Verify with `ssh root@thebeyond.internal 'ip route show 10.97.0.0/16'`
  — if missing, the §8.4 cleanup deploy would lose return-path
  connectivity. Address before retrying.

---

### 8.8 Abort criteria

Full abort (reverse all cutovers) if:

- More than one VLAN fails verification after cutover.
- BT8-gateway's transit interface goes down during the window
  (`ip addr show br-v255` returns empty) — root cause first, then
  retry.
- Mesh fabric goes degraded (`batctl o` shows no neighbors).
- Operator workstation loses path to both thebeyond AND BT8-gateway
  simultaneously (use the spare BT8 / serial console recovery).

Restore from `pre-phase3-cutover-backup.tar.gz` if BT8-gateway is in
an inconsistent state: `sysupgrade -r <backup>` on BT8-gateway
restores it to the post-§8.1 (inert staging) state. Then unwind
thebeyond if deployed: `nixos-rebuild switch --rollback` on
thebeyond rolls back the §8.4 deploy.

---

## Appendix A — Reference data table

Print this and keep it next to the laptop.

### Addressing (BT8-gateway side, end-of-Phase-2 state)

| Zone    | VLAN | Interface name (LuCI) | Bridge    | Gateway IP (this dev) | IPv6 ULA gateway            | DHCP? |
| ------- | ---- | --------------------- | --------- | --------------------- | --------------------------- | ----- |
| transit | 255  | `transit`             | `br-v255` | `10.255.255.2/30`     | `fdc6:55f2:0a5e:ffff::2/64` | no    |
| app     | 50   | `app`                 | `br-v50`  | `10.97.50.1/24`       | `fdc6:55f2:0a5e:1032::1/64` | yes   |
| network | 10   | `v10`                 | `br-v10`  | (none — L2 only)      | (none — L2 only)            | no    |
| dmz     | 100  | `v100`                | `br-v100` | (none — L2 only)      | (none — L2 only)            | no    |
| guest   | 30   | `guest`               | `br-v30`  | (none — L2 only)      | (none — L2 only)            | no    |
| adu     | 31   | `adu`                 | `br-v31`  | (none — L2 only)      | (none — L2 only)            | no    |
| iot     | 40   | `iot`                 | `br-v40`  | (none — L2 only)      | (none — L2 only)            | no    |
| game    | 41   | `game`                | `br-v41`  | (none — L2 only)      | (none — L2 only)            | no    |

**Phase 3 will add to this table** (these rows do **not** exist at
end of Phase 2; their L3 still lives on `thebeyond`):

| Zone       | VLAN | Interface name (LuCI) | Bridge   | Gateway IP (this dev, Phase 3) | IPv6 ULA gateway            | DHCP?       |
| ---------- | ---- | --------------------- | -------- | ------------------------------ | --------------------------- | ----------- |
| management | 11   | `management`          | `br-v11` | `10.97.11.1/24`                | `fdc6:55f2:0a5e:100b::1/64` | no (static) |
| netmgmt    | 12   | `netmgmt`             | `br-v12` | `10.97.12.1/24`                | `fdc6:55f2:0a5e:100c::1/64` | no (static) |
| trusted    | 20   | `home`                | `br-v20` | `10.97.20.1/24`                | `fdc6:55f2:0a5e:1014::1/64` | yes         |
| lab        | 21   | `lab`                 | `br-v21` | `10.97.21.1/24`                | `fdc6:55f2:0a5e:1015::1/64` | yes         |

### Upstream / external addresses (for DNS / NTP / static routes)

| What                                   | Address                                                                    |
| -------------------------------------- | -------------------------------------------------------------------------- |
| thebeyond's transit IPv4 (default GW)  | `10.255.255.1`                                                             |
| thebeyond's transit IPv6 (default GW)  | `fdc6:55f2:0a5e:ffff::1`                                                   |
| thebeyond's local DNS resolver (kresd) | `10.255.255.1` (port 53)                                                   |
| thebeyond's NTP server                 | `10.255.255.1` (port 123)                                                  |
| phantasma (recursive DNS)              | `10.91.10.10` (reachable via transit)                                      |
| BT8-bridge                             | `10.91.10.4` (reachable via transit)                                       |
| thebeyond MGMT                         | `10.91.10.1` (reachable via transit)                                       |
| basel ACME                             | `10.97.11.7` (currently via mesh → thebeyond; explicit fw rule in Phase 3) |

### Mesh parameters

| What                       | Value                                          |
| -------------------------- | ---------------------------------------------- |
| Mesh ID                    | `home-mesh`                                    |
| Encryption                 | `WPA3-SAE`                                     |
| Mesh forwarding            | `0` (disabled — batman-adv handles forwarding) |
| Routing algo               | `BATMAN_V`                                     |
| MTU on mesh / wired hardif | `1536`                                         |
| Gateway mode (batman)      | `off`                                          |

### LuCI menu cheat-sheet

| Task                         | LuCI path                                                     |
| ---------------------------- | ------------------------------------------------------------- |
| Set hostname / timezone      | System → System → General Settings                            |
| SSH keys / root password     | System → Administration                                       |
| Add wifi (mesh / AP)         | Network → Wireless → Add (per radio)                          |
| Create VLAN device / bridge  | Network → Interfaces → Devices tab → Add device configuration |
| Create interface (assign IP) | Network → Interfaces → Add new interface                      |
| Firewall zones / forwardings | Network → Firewall → General Settings (zones at bottom)       |
| Firewall rules               | Network → Firewall → Traffic Rules                            |
| DHCP / DNS forwarder         | Network → DHCP and DNS                                        |
| DHCP per-VLAN                | Network → DHCP and DNS → DHCP tab                             |
| Static leases                | Network → DHCP and DNS → Static Leases                        |
| NTP                          | System → System → Time Synchronization                        |
| Backup config                | System → Backup / Flash Firmware                              |
| Re-flash firmware            | System → Backup / Flash Firmware → Flash new firmware image   |
| Service enable/disable       | System → Startup                                              |

---

## Appendix B — Troubleshooting

### Symptom: `batctl n` empty after §5.D

- Check mesh PSK exactly matches BT8-bridge (typo most likely).
- Check mesh ID exactly = `home-mesh` (case-sensitive).
- Check both peers on same channel: `iw dev mesh0 info` on both ends.
- Check `mesh_fwding 0` actually applied: `iw dev mesh0 get mesh_param mesh_fwding`.
- Check signal: `iw dev mesh0 station dump | grep signal:`. Below
  -75 dBm is marginal; below -82 dBm is unusable.
- Reload wireless: `wifi down; wifi up`.

### Symptom: `ping 10.255.255.1` fails after §5.G/H

- `batctl o` — does `thebeyond` appear? If not, the wired hardif on
  BT8-bridge isn't reaching thebeyond. Check on BT8-bridge:
  `batctl n` should list thebeyond.
- `ip -d link show dev bat0.255` — confirm the VLAN device exists.
- `bridge link show` — confirm `bat0.255` and `<TRUNK>.255` are both
  bridge ports of `br-v255`.
- `tcpdump -ni br-v255 'arp or icmp'` — see if anything moves.
- On thebeyond: `tcpdump -ni brTRANSIT 'icmp'` — see if requests arrive.

### Symptom: ping works but DNS doesn't

- `nslookup example.com 127.0.0.1` — directly query dnsmasq
- `nslookup example.com 10.255.255.1` — bypass dnsmasq, hit kresd
- If second works but first doesn't: dnsmasq upstream is wrong;
  re-check **Network → DHCP and DNS → General → DNS forwardings**.

### Symptom: ping works, DNS works, but external scan shows BT8-gateway has no firewall

- `nft list ruleset | head -100` — confirm fw4 is loaded
- `fw4 print | less` — show the rendered ruleset
- `/etc/init.d/firewall status` — should be running
- Compare zone bindings: `uci show firewall | grep -E '(zone|forwarding)'`

### Symptom: APP clients get DHCP but no internet

(In Phase 2, APP is the only L3 zone served by BT8-gateway with DHCP,
so this is the relevant variant of the classic "DHCP works, traffic
doesn't" symptom. The same diagnostic pattern applies to any future
Phase 3 zone — substitute `br-v<vid>` and the matching gateway IP.)

- On the client: `ip route` — default should be `10.97.50.1`
- On the client: `nslookup example.com` — DNS works?
- On BT8-gateway: `tcpdump -ni br-v50 'icmp and src host <client-ip>'`
  while client pings 1.1.1.1 — see the request leave APP bridge
- On BT8-gateway: `tcpdump -ni br-v255 'icmp and src host <client-ip>'`
  — see it leave on transit
- If the request leaves but no reply: thebeyond's NAT may not be
  matching the source, or thebeyond is missing the `10.97.50.0/24 via
10.255.255.2` return route (see §6.4). Check on thebeyond:
  `nft list table inet filter | grep -A2 masquerade` and
  `ip route | grep 10.97.50`.

### Symptom: laptop loses LuCI access mid-config

Check, in order:

1. Did you reconfigure the port your laptop is on? (You shouldn't
   have — `<MGMT>` was supposed to stay in `br-lan`.)
2. Did the laptop's IP change? Renew DHCP: `dhclient -r && dhclient`
   on Linux, or unplug-replug the cable.
3. Try `192.168.1.1` (default `lan` on `br-lan`). In Phase 2 this is
   the only BT8-gateway LuCI surface; the management-VLAN address
   (`10.97.11.1`) does **not** exist on this device yet — that
   appears in Phase 3.
4. If `192.168.1.1` is unreachable: serial console (next section).

### Recovery: serial console

Plug your USB-serial into the BT8's serial header. Open with
`screen /dev/ttyUSB0 115200` (or `picocom`, `minicom`). Hit Enter to
get a prompt.

From the serial console you can:

- `ip addr show` — see actual interface state
- `cat /etc/config/network` — dump UCI to identify what went wrong
- Edit UCI directly: `vi /etc/config/network`, then `service network reload`
- Restore from backup: `sysupgrade -r /path/to/backup.tar.gz` (if
  you have it on the device's flash; otherwise, `scp` from another
  host on the same physical L2 segment)
- Last resort: factory reset via the failsafe boot mode (hold reset
  during power-on for 10s; device boots into failsafe with
  `192.168.1.1` and no password; `mtd erase rootfs_data && reboot`
  wipes config).

### Recovery: full re-flash

If the device is unrecoverable via SSH/serial/LuCI:

1. Power off the BT8.
2. Boot into the vendor recovery mode (per the BT8's hardware docs —
   typically a button-hold on power-up).
3. Use the vendor recovery tool to flash either:
   - `*-factory.bin` from §1.5 to redo OpenWrt with default config
     (you'll re-do Phase 5)
   - or the original vendor firmware to abort entirely
4. If the bootloader is intact but rootfs is broken, you can also
   boot from TFTP (per the BT8's documentation) and re-flash from
   there.

---

## Appendix C — Abort criteria

Stop and roll back to the previous BT8-as-gateway configuration if:

- After 30+ minutes of debugging, mesh peering with BT8-bridge still
  fails (suggests hardware/RF issue, not configuration).
- After 30+ minutes of debugging, `ping 10.255.255.1` fails with no
  packet visible at thebeyond's `brTRANSIT` (suggests the wired
  hardif from BT8-bridge to thebeyond is broken — different problem
  than this runbook covers).
- batman-adv throughput on `iperf3` between BT8-gateway and
  BT8-bridge is **< 100 Mbps on 5 GHz mesh** (canary for
  `openwrt/openwrt#18703` — slow-TX batman-adv on Filogic in 24.10.x;
  status on 25.12 unverified). If hit, fall back to a 24.10.5 image
  built with the same F.1 recipe (carry it in the operator secret
  store before the window per Phase 0b.8 in the checklist).
- Any cutover step that should take < 5 minutes is taking > 30
  minutes — you're in unknown territory and should regroup.

**Rollback procedure:**

1. Power off BT8-gateway.
2. Unplug the homelab L2 trunk from BT8-gateway, plug into the
   previous gateway device.
3. Power up the previous gateway (it should still have its known-good
   config).
4. Verify homelab connectivity. The homelab is back to pre-window
   state.
5. Take BT8-gateway offline for a follow-up debug session — do **not**
   leave it half-configured in the same physical location as the
   working gateway, or you'll confuse a future debug session.

---

## Appendix D — Post-window followups

Track these in the project's existing checklist
(`dual-gateway-app-vlan-checklist.md`); they are NOT part of the
window:

- Run the external security scan (Reference E in the plan)
- Update Phase 0b.13 checklist items
- Save the post-config sysupgrade backup into the operator secret store
- File a project memory if anything unexpected happened during the
  window (so future Claude can avoid the same trap)
- Schedule Phase 4 (Image Builder codification) — once stable, the
  manual UCI captured here becomes the test fixture for the
  declarative build
