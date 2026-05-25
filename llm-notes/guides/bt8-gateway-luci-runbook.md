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
- [ ] **Save a known-good rollback image**: keep the current production
  BT8's `sysupgrade.bin` (the one it's currently running) on your
  laptop in case you need to revert mid-window.
- [ ] **Have a USB-serial cable** ready and tested against the BT8's
  serial header (3.3V; baud rate per device docs — typically 115200
  8N1). This is your recovery path if LuCI access is lost.
- [ ] **Stage hardware**: BT8 device in office location, ethernet patch
  cable from BT8's `lan2` port to your laptop, power supply.
- [ ] **Confirm BT8-bridge is up and reachable.** From a host that can
  still reach it: `ssh root@10.91.10.4 'batctl n'`. The BT8-gateway
  will need an existing mesh peer to join.
- [ ] **Confirm `thebeyond` transit IP is up**: from any host on
  `network`/10, `ping 10.255.255.1` should succeed. (You will not be
  able to verify this once the homelab is down; do it now.)
- [ ] **Take photos** of the current cabling on the existing office
  gateway so you can rebuild it identically if you abort.
- [ ] **Tell anyone affected** that the homelab/internet is going down.

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

| Device       | Role                                  | Where it's reachable                          |
| ------------ | ------------------------------------- | --------------------------------------------- |
| `thebeyond`  | Internet gateway + WAN/NAT + most L3s | `10.91.10.1` (network); `10.255.255.1` (transit) |
| `BT8-bridge` | Wireless bridge — L2 passthrough only | `10.91.10.4` (network)                        |
| BT8 (legacy) | Will be wiped and re-flashed in Phase 1 below | (whatever it's on today)              |

L3 ownership by VLAN as of *right now* (verify before starting — if
any of this is wrong, the rollout has a pre-existing inconsistency
that must be resolved first):

| VLAN | Zone        | Subnet           | L3 lives on    | Permanent home / migration note         |
| ---- | ----------- | ---------------- | -------------- | --------------------------------------- |
| 10   | network     | `10.91.10.0/24`  | `thebeyond`    | permanent — stays on `thebeyond` forever |
| 11   | management  | `10.97.11.0/24`  | `thebeyond`    | moves to BT8-gateway in **Phase 3**     |
| 12   | netmgmt     | (new)            | (none yet)     | added on BT8-gateway in **Phase 3**     |
| 20   | trusted     | `10.97.20.0/24`  | `thebeyond`    | moves to BT8-gateway in **Phase 3**     |
| 21   | lab         | `10.97.21.0/24`  | `thebeyond`    | moves to BT8-gateway in **Phase 3**     |
| 30   | guest       | `10.91.30.0/24`  | `thebeyond`    | permanent                               |
| 31   | adu         | `10.91.31.0/24`  | `thebeyond`    | permanent                               |
| 40   | iot         | `10.91.40.0/24`  | `thebeyond`    | permanent                               |
| 41   | game        | `10.91.41.0/24`  | `thebeyond`    | permanent                               |
| 50   | app         | (new)            | (none yet)     | **added on BT8-gateway by this runbook** |
| 100  | dmz         | `10.97.100.0/24` | `thebeyond`    | permanent through Phase 5; later renumbers to `10.91.100` |
| 255  | transit     | `10.255.255.0/30`| `thebeyond` (.1) | **BT8-gateway picks up .2 in this runbook** |

(Phase 1 of the plan already added `app`, `netmgmt`, and `transit`
zones to `thebeyond`'s NixOS config: APP and NETMGMT as member-only
bridges with no IP on `thebeyond`, transit with `10.255.255.1/30`.)

### Target state (when this runbook completes)

BT8-gateway will be the L3 gateway for **only**:

| VLAN | Zone    | IPv4              | IPv6                            |
| ---- | ------- | ----------------- | ------------------------------- |
| 50   | app     | `10.97.50.1/24`   | `fdc6:55f2:0a5e:1032::1/64`     |
| 255  | transit | `10.255.255.2/30` | `fdc6:55f2:0a5e:ffff::2/64`     |

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

### What stays working throughout this runbook

This is the reachability assurance: nothing in the existing homelab
should break while BT8-gateway is brought up.

- **Existing management/trusted/lab/DMZ/network traffic** continues
  flowing through `thebeyond` unchanged. BT8-gateway is added to the
  mesh as a peer but does not intercept any of these VLANs in Phase 2.
- **Existing homelab → internet path** is untouched: clients still
  default-route to their existing `thebeyond`-side gateway, then NAT
  out via `thebeyond`.
- **APP traffic** has no production clients yet (Phase 5 of the plan
  moves services into APP). The L3 you stand up here is infrastructure
  for that future work.
- **Operator laptop access**: the laptop stays on the BT8-gateway's
  `<MGMT>` wired port in `br-lan` (default `192.168.1.0/24`)
  throughout the runbook. That's how LuCI and SSH access work during
  config. The `lan` fw4 zone is preserved for this reason (the
  full-cutover variant of this runbook would delete it; we don't).

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

Approximate duration: **2–4 hours** of active work, plus testing
buffer. (Shorter than the full-cutover variant — Phase 2 stands up
only the APP and transit zones; the management/trusted/lab/netmgmt
zones are deferred to Phase 3.)

The discrete phases inside this runbook (numbered locally; do not
confuse with the plan's phase numbers):

1. **Phase 1** — Build the image via Firmware Selector. Do this
   pre-window; takes ~5 minutes once you have the recipe.
2. **Phase 2** — Flash the BT8 from stock to OpenWrt 25.12. Takes
   ~10 minutes plus first-boot.
3. **Phase 3** — First-boot LuCI setup (root password, SSH).
4. **Phase 4** — Post-flash SSH verification (must pass before any UCI).
5. **Phase 5** — LuCI step-by-step configuration. Discrete Save &
   Apply checkpoints; restricted to the APP + transit L3 commitments.
6. **Phase 6** — Cabling cutover (BT8-gateway joins the mesh), final
   verification. Existing homelab cabling is **not** disturbed in
   Phase 2; nothing migrates off `thebeyond` here.

You can pause between any two checkpoints to think, eat, sleep, or
abort. The checkpoints between **5.M (firewall zones complete)** and
**5.O (DHCP enabled)** are the riskiest — if you must abort during the
window, abort BEFORE 5.M (the BT8 can sit configured but inert) or
AFTER 5.O (DHCP is serving on APP and you can verify clients work).

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
  + the firewall and batman-adv protocol handlers in LuCI.
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

| VLAN ID | Name       | Purpose                                              |
| ------- | ---------- | ---------------------------------------------------- |
| 10      | `bat0.10`  | network — L2 passthrough                             |
| 30      | `bat0.30`  | untrusted (GUEST) — L2 passthrough                   |
| 31      | `bat0.31`  | adu — L2 passthrough                                 |
| 40      | `bat0.40`  | iot — L2 passthrough                                 |
| 41      | `bat0.41`  | game — L2 passthrough                                |
| 50      | `bat0.50`  | app — **L3 terminated here** (the new APP gateway)   |
| 100     | `bat0.100` | dmz — L2 passthrough                                 |
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

| VLAN ID | Name             |
| ------- | ---------------- |
| 10      | `<TRUNK>.10`     |
| 30      | `<TRUNK>.30`     |
| 31      | `<TRUNK>.31`     |
| 40      | `<TRUNK>.40`     |
| 41      | `<TRUNK>.41`     |
| 50      | `<TRUNK>.50`     |
| 100     | `<TRUNK>.100`    |
| 255     | `<TRUNK>.255`    |

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

| Bridge   | VLAN | L3?            | Members                       |
| -------- | ---- | -------------- | ----------------------------- |
| `br-lan` | —    | mgmt only      | `lan2` (laptop), default LAN  |
| `br-v10` | 10   | L2 passthrough | `bat0.10`, `<TRUNK>.10`       |
| `br-v30` | 30   | L2 passthrough | `bat0.30`, `<TRUNK>.30`       |
| `br-v31` | 31   | L2 passthrough | `bat0.31`, `<TRUNK>.31`       |
| `br-v40` | 40   | L2 passthrough | `bat0.40`, `<TRUNK>.40`       |
| `br-v41` | 41   | L2 passthrough | `bat0.41`, `<TRUNK>.41`       |
| `br-v50` | 50   | **L3 — APP**   | `bat0.50`, `<TRUNK>.50`       |
| `br-v100`| 100  | L2 passthrough | `bat0.100`, `<TRUNK>.100`     |
| `br-v255`| 255  | **L3 — transit** | `bat0.255`, `<TRUNK>.255`   |

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

| Zone      | Interface  | Input    | Output | Forward  | Purpose                                        |
| --------- | ---------- | -------- | ------ | -------- | ---------------------------------------------- |
| `lan`     | `lan` (default `br-lan`) | `accept` | `accept` | `reject` | **KEEP** — operator laptop cable; LuCI/SSH surface during the runbook |
| `transit` | `transit`  | `reject` | `accept` | `reject` | Uplink to `thebeyond` (point-to-point /30)     |
| `app`     | `app`      | `reject` | `accept` | `reject` | New APP zone (10.97.50.0/24)                   |

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

| Source | Destination | Purpose                                       |
| ------ | ----------- | --------------------------------------------- |
| `app`  | `transit`   | APP clients → internet/DMZ via thebeyond      |

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

## Phase 6 — Cabling cutover and final verification

> **Phase 2 scope reminder.** BT8-gateway is now an APP + transit
> gateway plus an L2-passthrough box for everything else. Cutover here
> means **joining BT8-gateway to the mesh and to the homelab L2
> switch's trunk**; it does **not** move any L3 ownership off
> `thebeyond`. The non-APP homelab keeps routing through
> `thebeyond` (now via mesh → BT8-gateway → wire), exactly as before.

### 6.1 Cable BT8-gateway into the homelab trunk

Cable the homelab L2 switch onto `<TRUNK>` on BT8-gateway. The
downstream side needs to be a tagged 802.1q trunk carrying:

- **VLAN 50** (APP) — terminated here; clients on this VLAN will get
  an address from BT8-gateway's dnsmasq.
- **VLAN 10, 30, 31, 40, 41, 100** — passthrough; frames cross the
  bridge into `bat0.<vid>` and reach `thebeyond` over the mesh.
- **VLAN 255** (transit) — usually mesh-only between BT8-gateway and
  `thebeyond`, but trunking it on the wire is harmless and is
  required as a fallback if the mesh degrades.

**Do NOT trunk VLANs 11, 12, 20, 21 yet.** Their L3 still lives on
`thebeyond` and is reached via mesh; if you trunk them through here,
the L2 switch sees the same MAC on both the mesh-side path
(via thebeyond) and the wired path (still going through... nothing
on this device), which can poison the switch's MAC table. Phase 3 is
when these VLANs join the trunk on the wire.

If the homelab L2 switch is OpenWrt and you're managing it
out-of-flake (per Reference D in the plan), update its UCI to trunk
the Phase-2 VLAN set on the uplink to BT8-gateway. The L2 switch's
own management address stays where it is today (on `network`/10 via
`thebeyond`); `netmgmt`/12 is a Phase 3 / follow-up plan deliverable.

### 6.2 Verify from the homelab side — APP

If you have a test client to attach to APP (a laptop on a VLAN 50
access port, or an existing host you can re-VLAN onto 50 temporarily):

```sh
ip route                          # default via 10.97.50.1
ping 10.97.50.1                   # BT8-gateway local APP gateway
ping 10.255.255.1                 # thebeyond via transit
ping 1.1.1.1                      # internet (via thebeyond NAT)
ping 10.91.10.10                  # phantasma via transit → thebeyond
nslookup example.com              # DNS via thebeyond's kresd
```

If APP has no client to test with yet (likely — Phase 5 of the plan
moves services into APP), skip this and verify §6.3 instead.

### 6.3 Verify from the homelab side — passthrough still works

This is the **regression check**: nothing the homelab depends on
should have broken. From a host on a passthrough VLAN that previously
worked (e.g., a NAS on `network`/10, or anything on
`management`/11 / `trusted`/20):

```sh
ip route                          # unchanged from before the window
                                  # (still defaults via thebeyond's IP on this VLAN)
ping <thebeyond's IP on this VLAN>  # routes via wire → BT8-gateway → mesh → thebeyond
ping 1.1.1.1                      # internet via thebeyond NAT
nslookup example.com              # DNS via thebeyond's kresd
```

If a passthrough VLAN that worked yesterday doesn't work now: most
likely the bridge for that VLAN is missing on BT8-gateway, or the
homelab L2 switch isn't trunking the VLAN to BT8-gateway, or the
batman peer relationship between BT8-gateway and `thebeyond` has
flapped. See [Troubleshooting](#troubleshooting).

### 6.4 Confirm cross-gateway route on `thebeyond` (APP)

`thebeyond` needs a route to APP's subnet that points back at
BT8-gateway (`10.97.50.0/24 via 10.255.255.2`). This was configured
in `hosts/thebeyond/router.nix` as part of Phase 1.

```sh
# From BT8-gateway (over transit):
ssh root@10.255.255.1 ip route | grep -E '10\.97\.50|10\.97\.12'
# Expect at minimum: 10.97.50.0/24 via 10.255.255.2 dev brTRANSIT
# (netmgmt/12 may or may not be present in Phase 1; that's fine
# either way for Phase 2 since no traffic uses it yet)
```

If the APP route is missing on thebeyond, Phase 1 wasn't fully
deployed. Open `hosts/thebeyond/router.nix` (the repo is fine to
read offline from your laptop), confirm the route entry exists, and
redeploy thebeyond. **This is the only thing in this runbook that
requires touching the NixOS config**; everything else is OpenWrt-side.

### 6.5 Verify the wifi SSIDs you brought up in §5.Q (if any)

If you stood up GUEST/IOT/GAME/ADU SSIDs on this device:

- Connect a client to each SSID in turn.
- Confirm DHCP lease arrived from `thebeyond` (the L3 gateway).
- Browse a website / `ping 1.1.1.1`.

HOME wifi was deferred — keep it on the existing hardware.

### 6.6 External security scan (deferred)

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

---

## Phase 3 (separate future window — not this runbook)

This runbook ends with BT8-gateway in the **Phase 2 steady state**:
APP + transit L3 here, everything else still routing through
`thebeyond` via mesh-passthrough. Phase 3 of the [migration
plan](../wip/dual-gateway-app-vlan-plan.md#phase-3--cutover-vlans-with-host-renumbering)
is what completes the dual-gateway model.

Phase 3 is a **per-VLAN** cutover: one VLAN at a time, in a single
coordinated change that simultaneously (a) removes the IP from
`thebeyond`'s side of the mesh and (b) adds it on BT8-gateway. Doing
both in the same window avoids the duplicate-IP / ARP-collision
window that would happen if you brought the BT8-gateway address up
first or tore the thebeyond address down first.

The four Phase 3 cutovers, roughly in the order recommended by the
plan:

1. **`netmgmt`/12** — net-new; no IP to remove on `thebeyond`. Safest
   to do first as a dry run of the Phase 3 cutover mechanics.
2. **`lab`/21** — semi-trusted; clients re-DHCP onto BT8-gateway and
   pick up new leases. Brief disconnect window.
3. **`trusted`/20 (HOME)** — same shape as `lab`. Notify household
   first.
4. **`management`/11** — highest-impact (VM admin plane). Save for
   last; coordinate with any in-flight ops.

Each cutover involves:

- **NixOS side (thebeyond)**: drop the zone from `router.nix`,
  redeploy. The matching `mkVlanBridge` becomes a no-op.
- **LuCI side (BT8-gateway)**: extend §5.E with `bat0.<vid>`, §5.F
  with `<TRUNK>.<vid>`, §5.J with the L3-terminating bridge, §5.M
  with the fw4 zone, §5.M.1 with the new forwardings (e.g.,
  `management → app`, `management → transit`), §5.M.2 with the
  per-zone input rules (Allow-SSH-mgmt, Allow-LuCI-mgmt,
  app-basel-ACME), §5.O with the DHCP pool.
- **Homelab L2 switch side**: add the VLAN to the trunk toward
  BT8-gateway (was withheld in §6.1 of this runbook).

The full Phase 3 procedure lives in a separate runbook to be written
when the operator is ready to schedule the first cutover. The tables
and section structure above are designed so that "Phase 3 extends
§5.X" reads cleanly when that runbook is drafted.

---

## Appendix A — Reference data table

Print this and keep it next to the laptop.

### Addressing (BT8-gateway side, end-of-Phase-2 state)

| Zone        | VLAN | Interface name (LuCI) | Bridge   | Gateway IP (this dev) | IPv6 ULA gateway              | DHCP? |
| ----------- | ---- | --------------------- | -------- | --------------------- | ----------------------------- | ----- |
| transit     | 255  | `transit`             | `br-v255`| `10.255.255.2/30`     | `fdc6:55f2:0a5e:ffff::2/64`   | no    |
| app         | 50   | `app`                 | `br-v50` | `10.97.50.1/24`       | `fdc6:55f2:0a5e:1032::1/64`   | yes   |
| network     | 10   | `v10`                 | `br-v10` | (none — L2 only)      | (none — L2 only)              | no    |
| dmz         | 100  | `v100`                | `br-v100`| (none — L2 only)      | (none — L2 only)              | no    |
| guest       | 30   | `guest`               | `br-v30` | (none — L2 only)      | (none — L2 only)              | no    |
| adu         | 31   | `adu`                 | `br-v31` | (none — L2 only)      | (none — L2 only)              | no    |
| iot         | 40   | `iot`                 | `br-v40` | (none — L2 only)      | (none — L2 only)              | no    |
| game        | 41   | `game`                | `br-v41` | (none — L2 only)      | (none — L2 only)              | no    |

**Phase 3 will add to this table** (these rows do **not** exist at
end of Phase 2; their L3 still lives on `thebeyond`):

| Zone        | VLAN | Interface name (LuCI) | Bridge   | Gateway IP (this dev, Phase 3) | IPv6 ULA gateway              | DHCP? |
| ----------- | ---- | --------------------- | -------- | ------------------------------ | ----------------------------- | ----- |
| management  | 11   | `management`          | `br-v11` | `10.97.11.1/24`                | `fdc6:55f2:0a5e:100b::1/64`   | no (static) |
| netmgmt     | 12   | `netmgmt`             | `br-v12` | `10.97.12.1/24`                | `fdc6:55f2:0a5e:100c::1/64`   | no (static) |
| trusted     | 20   | `home`                | `br-v20` | `10.97.20.1/24`                | `fdc6:55f2:0a5e:1014::1/64`   | yes   |
| lab         | 21   | `lab`                 | `br-v21` | `10.97.21.1/24`                | `fdc6:55f2:0a5e:1015::1/64`   | yes   |

### Upstream / external addresses (for DNS / NTP / static routes)

| What                                    | Address                                |
| --------------------------------------- | -------------------------------------- |
| thebeyond's transit IPv4 (default GW)   | `10.255.255.1`                         |
| thebeyond's transit IPv6 (default GW)   | `fdc6:55f2:0a5e:ffff::1`               |
| thebeyond's local DNS resolver (kresd)  | `10.255.255.1` (port 53)               |
| thebeyond's NTP server                  | `10.255.255.1` (port 123)              |
| phantasma (recursive DNS)               | `10.91.10.10` (reachable via transit)  |
| BT8-bridge                              | `10.91.10.4` (reachable via transit)   |
| thebeyond MGMT                          | `10.91.10.1` (reachable via transit)   |
| basel ACME                              | `10.97.11.7` (currently via mesh → thebeyond; explicit fw rule in Phase 3) |

### Mesh parameters

| What             | Value          |
| ---------------- | -------------- |
| Mesh ID          | `home-mesh`    |
| Encryption       | `WPA3-SAE`     |
| Mesh forwarding  | `0` (disabled — batman-adv handles forwarding) |
| Routing algo     | `BATMAN_V`     |
| MTU on mesh / wired hardif | `1536`  |
| Gateway mode (batman) | `off`     |

### LuCI menu cheat-sheet

| Task                              | LuCI path                                                    |
| --------------------------------- | ------------------------------------------------------------ |
| Set hostname / timezone           | System → System → General Settings                           |
| SSH keys / root password          | System → Administration                                      |
| Add wifi (mesh / AP)              | Network → Wireless → Add (per radio)                         |
| Create VLAN device / bridge       | Network → Interfaces → Devices tab → Add device configuration|
| Create interface (assign IP)      | Network → Interfaces → Add new interface                     |
| Firewall zones / forwardings      | Network → Firewall → General Settings (zones at bottom)      |
| Firewall rules                    | Network → Firewall → Traffic Rules                           |
| DHCP / DNS forwarder              | Network → DHCP and DNS                                       |
| DHCP per-VLAN                     | Network → DHCP and DNS → DHCP tab                            |
| Static leases                     | Network → DHCP and DNS → Static Leases                       |
| NTP                               | System → System → Time Synchronization                       |
| Backup config                     | System → Backup / Flash Firmware                             |
| Re-flash firmware                 | System → Backup / Flash Firmware → Flash new firmware image  |
| Service enable/disable            | System → Startup                                             |

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
