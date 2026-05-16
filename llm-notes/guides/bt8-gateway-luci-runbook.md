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

## Window structure

Approximate duration: **2–4 hours** of active work, plus testing
buffer. The discrete phases:

1. **Phase 1** — Build the image via Firmware Selector. Do this
   pre-window; takes ~5 minutes once you have the recipe.
2. **Phase 2** — Flash the BT8 from stock to OpenWrt 25.12. Takes
   ~10 minutes plus first-boot.
3. **Phase 3** — First-boot LuCI setup (root password, SSH).
4. **Phase 4** — Post-flash SSH verification (must pass before any UCI).
5. **Phase 5** — LuCI step-by-step configuration. ~20 discrete Save &
   Apply checkpoints.
6. **Phase 6** — Cabling cutover (homelab gear → BT8-gateway), final
   verification.

You can pause between any two checkpoints to think, eat, sleep, or
abort. The checkpoints between **5.M (firewall zones complete)** and
**5.N (DHCP enabled)** are the riskiest — if you must abort during the
window, abort BEFORE 5.M (the BT8 can sit configured but inert) or
AFTER 5.N (DHCP is serving and you can verify clients work).

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

You need a `bat0.<vid>` for **every VLAN this device touches** — both
L3-terminating ones and L2-only passthrough ones. Without `bat0.<vid>`,
frames for that VLAN have nowhere to land on this device.

**Network → Interfaces → Devices** tab → **Add device configuration...**

For each VLAN in the table below, create one device:

- **Type**: `VLAN (802.1q)`
- **Base device**: `bat0`
- **VLAN ID**: as listed
- (LuCI auto-fills the device name as `bat0.<vid>`)

| VLAN ID | Name      | Purpose                         |
| ------- | --------- | ------------------------------- |
| 10      | `bat0.10` | network — L2 passthrough        |
| 11      | `bat0.11` | management — L3 here            |
| 12      | `bat0.12` | netmgmt — L3 here               |
| 20      | `bat0.20` | trusted (HOME) — L3 here        |
| 21      | `bat0.21` | lab — L3 here                   |
| 30      | `bat0.30` | untrusted (GUEST) — passthrough |
| 31      | `bat0.31` | adu — passthrough               |
| 40      | `bat0.40` | iot — passthrough               |
| 41      | `bat0.41` | game — passthrough              |
| 50      | `bat0.50` | app — L3 here                   |
| 99      | `bat0.99` | transit — L3 here               |
| 100     | `bat0.100`| dmz — passthrough               |

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

| VLAN ID | Name             |
| ------- | ---------------- |
| 10      | `<TRUNK>.10`     |
| 11      | `<TRUNK>.11`     |
| 12      | `<TRUNK>.12`     |
| 20      | `<TRUNK>.20`     |
| 21      | `<TRUNK>.21`     |
| 30      | `<TRUNK>.30`     |
| 31      | `<TRUNK>.31`     |
| 40      | `<TRUNK>.40`     |
| 41      | `<TRUNK>.41`     |
| 50      | `<TRUNK>.50`     |
| 99      | `<TRUNK>.99`     |
| 100     | `<TRUNK>.100`    |

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

### 5.G — Create the transit bridge and interface (HIGHEST PRIORITY VLAN)

Configure transit first because everything else (default route, DNS,
NTP) flows through it. If you only get one VLAN working today, this
is the one.

**Network → Interfaces → Devices** tab → **Add device configuration...**

- **Type**: `Bridge device`
- **Device name**: `br-v99`
- **Bridge ports**: select `bat0.99` AND `<TRUNK>.99`
- (Leave bridge VLAN filtering OFF — we are not using bridge-vlan-filtering;
  one bridge per VLAN is the model here.)

**Save** the device.

**Network → Interfaces → Add new interface...**

- **Name**: `transit`
- **Protocol**: `Static address`
- **Device**: `br-v99`

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
ip -4 addr show dev br-v99       # should show 10.255.255.2/30
ip -6 addr show dev br-v99       # should show fdc6:55f2:0a5e:ffff::2/64
ip route                         # should show 'default via 10.255.255.1 dev br-v99'
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
- Run `tcpdump -ni br-v99 'icmp'` while pinging from another
  terminal — confirm packets are leaving on `br-v99`.
- Run `tcpdump -ni bat0.99 'icmp'` — confirm batman is carrying them.
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

### 5.J — Create the L3-terminating VLAN bridges and interfaces

For each L3-terminating VLAN below, repeat the pattern from §5.G
(bridge device + interface with static IP). Do them **one at a time**
with a Save & Apply after each.

**`app` / VLAN 50:**

- Bridge `br-v50`, members: `bat0.50`, `<TRUNK>.50`
- Interface `app`, protocol Static, device `br-v50`
  - IPv4: `10.97.50.1` / `255.255.255.0`
  - IPv6 address: `fdc6:55f2:0a5e:1032::1/64`
  - No IPv4 gateway (default route is via transit)
  - **Save & Apply**, then `ip addr show dev br-v50` to verify.

**`netmgmt` / VLAN 12** (for the homelab L2 switch and other wired-to-BT8 net gear):

- Bridge `br-v12`, members: `bat0.12`, `<TRUNK>.12`
- Interface `netmgmt`, protocol Static, device `br-v12`
  - IPv4: `10.97.12.1` / `255.255.255.0`
  - IPv6 address: `fdc6:55f2:0a5e:100c::1/64`
  - **Save & Apply**, verify.

**`management` / VLAN 11** (for VM hosts, NAS, BMC):

- Bridge `br-v11`, members: `bat0.11`, `<TRUNK>.11`
- Interface `management`, protocol Static, device `br-v11`
  - IPv4: `10.97.11.1` / `255.255.255.0`
  - IPv6 address: `fdc6:55f2:0a5e:100b::1/64`
  - **Save & Apply**, verify.

**`trusted` / VLAN 20** (HOME):

- Bridge `br-v20`, members: `bat0.20`, `<TRUNK>.20`
- Interface `home`, protocol Static, device `br-v20`
  - IPv4: `10.97.20.1` / `255.255.255.0`
  - IPv6 address: `fdc6:55f2:0a5e:1014::1/64`
  - **Save & Apply**, verify.

**`lab` / VLAN 21:**

- Bridge `br-v21`, members: `bat0.21`, `<TRUNK>.21`
- Interface `lab`, protocol Static, device `br-v21`
  - IPv4: `10.97.21.1` / `255.255.255.0`
  - IPv6 address: `fdc6:55f2:0a5e:1015::1/64`
  - **Save & Apply**, verify.

After all five: `ip -br addr show | grep br-v` should list all five
bridges with their `.1` addresses.

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

In SSH:

```sh
ip -br link    | sort                # all br-v*, bat0.*, lan*.* devices present
ip -br addr -4 | grep 'br-v'         # 5 entries: v11, v12, v20, v21, v50, v99
                                     # (transit shows .2; others show .1)
ping -c 2 10.255.255.1               # transit still works
ping -c 2 1.1.1.1                    # internet still works
nft list ruleset | head -50          # default fw4 ruleset present
                                     # (still permissive — no zones added yet)
```

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

**Network → Firewall → General Settings** tab:

- **Drop invalid packets**: enabled
- **Input**: `reject`
- **Output**: `accept`
- **Forward**: `reject`

Now switch to the **Zones** section. Delete the default `lan` and
`wan` zones (they refer to interfaces we're not using in their
default form). Click the trash icon on each.

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

**Add the `management` zone:**

- **Name**: `management`
- **Input**: `accept`, **Output**: `accept`, **Forward**: `reject`
- **Covered networks**: `management`

**Add the `netmgmt` zone:**

- **Name**: `netmgmt`
- **Input**: `reject` (locked-down infra plane; SSH allowed via explicit rule below)
- **Output**: `accept`, **Forward**: `reject`
- **Covered networks**: `netmgmt`

**Add the `trusted` zone:**

- **Name**: `trusted`
- **Input**: `accept`, **Output**: `accept`, **Forward**: `reject`
- **Covered networks**: `home`

**Add the `lab` zone:**

- **Name**: `lab`
- **Input**: `accept`, **Output**: `accept`, **Forward**: `reject`
- **Covered networks**: `lab`

(Note: no fw4 zone for `network`/10, `guest`/30, `adu`/31, `iot`/40,
`game`/41, or `dmz`/100 — these are L2-only on this device, no L3
interface to bind. Their fw enforcement runs on thebeyond.)

### 5.M.1 — Add inter-zone forwardings

Still on **Network → Firewall**, scroll to **Inter-Zone Forwarding**.

Add each pair below (one per row):

| Source       | Destination  | Purpose                                       |
| ------------ | ------------ | --------------------------------------------- |
| `trusted`    | `transit`    | HOME → internet/DMZ/iot via thebeyond         |
| `trusted`    | `app`        | HOME → APP services                           |
| `trusted`    | `management` | HOME → VM/NAS admin                           |
| `lab`        | `management` | LAB → admin                                   |
| `lab`        | `lab`        | LAB intra-zone (most fw4 zones need this)     |
| `lab`        | `transit`    | LAB → internet/DMZ via thebeyond              |
| `app`        | `transit`    | APP → internet/DMZ via thebeyond              |
| `management` | `management` | management intra-zone                         |
| `management` | `trusted`    | admin → HOME                                  |
| `management` | `app`        | admin → APP                                   |
| `management` | `transit`    | admin → internet/DMZ via thebeyond            |
| `management` | `netmgmt`    | admin → switch/PDU/BMC CLI                    |
| `netmgmt`    | `transit`    | netmgmt outbound NTP/DNS only (no inbound)    |

Now **Save & Apply** the whole firewall page.

### 5.M.2 — Add explicit traffic rules

**Network → Firewall → Traffic Rules** tab.

You should see existing default rules (Allow-DHCP-Renew,
Allow-Ping-WAN, etc.). Most will reference `wan` which no longer
exists; either delete them or leave them — they will be inert without
a `wan` zone. Cleanest is to **delete every default rule** and add
back only what we explicitly need.

**Add: Allow DNS and DHCP to BT8-gateway from any zone**

- **Name**: `Allow-DNS-DHCP`
- **Protocol**: `TCP UDP`
- **Source zone**: `Any zone`
- **Destination zone**: `Device (input)`
- **Destination port**: `53 67 547`
- **Action**: `accept`
- (Optional rate-limit) **Extra arguments**: `--limit 100/sec`

**Add: Allow ICMP echo from any zone (diagnostics)**

- **Name**: `Allow-ICMP`
- **Protocol**: `ICMP`
- **Source zone**: `Any zone`
- **Destination zone**: `Device (input)`
- **Action**: `accept`

**Add: Allow SSH from management** (so admin from VM/NAS workstations works):

- **Name**: `Allow-SSH-mgmt`
- **Protocol**: `TCP`
- **Source zone**: `management`
- **Destination zone**: `Device (input)`
- **Destination port**: `22`
- **Action**: `accept`

**Add: Allow LuCI from management** (HTTP/HTTPS):

- **Name**: `Allow-LuCI-mgmt`
- **Protocol**: `TCP`
- **Source zone**: `management`
- **Destination zone**: `Device (input)`
- **Destination port**: `80 443`
- **Action**: `accept`

**Add: Allow APP → basel ACME** (Phase 5 services need cert renewal):

- **Name**: `app-basel-ACME`
- **Protocol**: `TCP`
- **Source zone**: `app`
- **Destination zone**: `management`
- **Destination IP**: `10.97.11.7`
- **Destination port**: `443`
- **Action**: `accept`

**Save & Apply.**

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

For each L3-terminating VLAN that should hand out leases, configure a
DHCP pool. **Skip `management` and `netmgmt`** — both use static IPs
from the registry (DHCP off there).

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

**`home` (trusted, VLAN 20):**

- Same pattern as `app`. Pool start `100`, limit `100`.

**`lab` (VLAN 21):**

- Same pattern. Pool start `100`, limit `100`.

**Save & Apply** between each.

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

**Network → Wireless → Add** on `radio1` (5 GHz) or `radio0` (2.4 GHz):

For HOME wifi:

- **General Setup** tab:
  - **Mode**: `Access Point`
  - **ESSID**: your HOME SSID
  - **Network**: `home` (the trusted/20 interface — this binds the
    SSID to bridge `br-v20`, which is L3-terminated here)
- **Wireless Security** tab:
  - **Encryption**: `WPA3-SAE` or `WPA2-PSK/WPA3-SAE Mixed Mode`
  - **Key**: HOME PSK from secret store

Repeat for GUEST (network `guest`, the L2-passthrough interface for
br-v30), IOT (network `iot`), GAME (network `game`).

**Important:** for the L2-passthrough zones, the `Network` field
binds to the **interface name** (`guest`, `iot`, `game`) — these
interfaces have `proto 'none'` and are bridged into the matching
`br-v30` / `br-v40` / `br-v41`. The SSID injects client frames
directly into the bridge tagged with the right VID; batman delivers
them to thebeyond, which is the L3 gateway for those zones.

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

### 6.1 Move the homelab gear onto BT8-gateway

Cable the homelab L2 switch (or whatever currently terminates the
homelab gear) onto `<TRUNK>` on the BT8-gateway. The downstream side
needs to be a tagged 802.1q trunk carrying:

- VLAN 11 (management — for VM hosts)
- VLAN 12 (netmgmt — for the homelab L2 switch's own mgmt address)
- VLAN 20 (HOME — if any wired home gear)
- VLAN 21 (LAB)
- VLAN 50 (APP)
- VLAN 30/31/40/41/100 (passthrough — only if any wired gear in
  those zones)

If the homelab L2 switch is OpenWrt and you're managing it
out-of-flake (per Reference D in the plan), update its UCI to:

- Bind a management IP on `netmgmt`/12 (e.g., `10.97.12.<id>`)
- Trunk the above VLANs on the uplink port to BT8-gateway

### 6.2 Verify from the homelab side

From a host on `management` (e.g., a VM host that just got an IP via
BT8-gateway's DHCP, or a static-IP NAS):

```sh
ip route                          # default via 10.97.11.1 (or .12.1, .20.1, etc.
                                  # depending on which VLAN you're on)
ping 10.97.11.1                   # BT8-gateway local-zone gateway
ping 10.255.255.1                 # thebeyond via transit
ping 1.1.1.1                      # internet
ping 10.91.10.10                  # phantasma via transit → thebeyond → brMGMT
nslookup example.com              # DNS via thebeyond's kresd
```

All five must work. If any fails, see [Troubleshooting](#troubleshooting).

### 6.3 Confirm cross-gateway routes on `thebeyond`

`thebeyond` needs static routes for the BT8-gw side. These are
configured in `hosts/thebeyond/router.nix` (per Phase 1 of the plan)
and should already be live since you redeployed thebeyond before
starting this runbook. Verify from a third host (or from
BT8-gateway):

```sh
# From BT8-gateway:
ssh root@10.255.255.1 ip route | grep 10.97
# Expect: 10.97.0.0/16 via 10.255.255.2 dev brTRANSIT
```

If that route is missing on thebeyond: the `router6.routes` config
didn't take. Open `hosts/thebeyond/router.nix` (you can do this from
your laptop if you have the repo cloned locally — no internet needed
for the read), confirm the route entry exists, and redeploy
thebeyond. **This is the only thing in this runbook that requires
touching the NixOS config**; everything else is OpenWrt-side.

### 6.4 Verify from a HOME wifi client

If you brought up wifi SSIDs in §5.Q: connect a client to the HOME
SSID:

- Confirm DHCP lease arrived in `10.97.20.100`–`10.97.20.199` range
- Browse a website
- `ping 10.97.20.1` (BT8-gw local), `ping 1.1.1.1` (internet)

### 6.5 External security scan (deferred)

Per the plan checklist Phase 0b.13, run the external security scan
runbook (Reference E in the plan) within ~24h of cutover from an
off-network host. **This does NOT have to happen during the
maintenance window** — schedule for a follow-up day with full
internet/dev environment available.

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

## Appendix A — Reference data table

Print this and keep it next to the laptop.

### Addressing (BT8-gateway side)

| Zone        | VLAN | Interface name (LuCI) | Bridge   | Gateway IP (this dev) | IPv6 ULA gateway              | DHCP? |
| ----------- | ---- | --------------------- | -------- | --------------------- | ----------------------------- | ----- |
| transit     | 99   | `transit`             | `br-v99` | `10.255.255.2/30`     | `fdc6:55f2:0a5e:ffff::2/64`   | no    |
| app         | 50   | `app`                 | `br-v50` | `10.97.50.1/24`       | `fdc6:55f2:0a5e:1032::1/64`   | yes   |
| management  | 11   | `management`          | `br-v11` | `10.97.11.1/24`       | `fdc6:55f2:0a5e:100b::1/64`   | no (static) |
| netmgmt     | 12   | `netmgmt`             | `br-v12` | `10.97.12.1/24`       | `fdc6:55f2:0a5e:100c::1/64`   | no (static) |
| trusted     | 20   | `home`                | `br-v20` | `10.97.20.1/24`       | `fdc6:55f2:0a5e:1014::1/64`   | yes   |
| lab         | 21   | `lab`                 | `br-v21` | `10.97.21.1/24`       | `fdc6:55f2:0a5e:1015::1/64`   | yes   |
| network     | 10   | `v10`                 | `br-v10` | (none — L2 only)      | (none — L2 only)              | no    |
| dmz         | 100  | `v100`                | `br-v100`| (none — L2 only)      | (none — L2 only)              | no    |
| guest       | 30   | `guest`               | `br-v30` | (none — L2 only)      | (none — L2 only)              | no    |
| adu         | 31   | `adu`                 | `br-v31` | (none — L2 only)      | (none — L2 only)              | no    |
| iot         | 40   | `iot`                 | `br-v40` | (none — L2 only)      | (none — L2 only)              | no    |
| game        | 41   | `game`                | `br-v41` | (none — L2 only)      | (none — L2 only)              | no    |

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
| basel ACME                              | `10.97.11.7` (local; explicit fw rule) |

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
- `ip -d link show dev bat0.99` — confirm the VLAN device exists.
- `bridge link show` — confirm `bat0.99` and `<TRUNK>.99` are both
  bridge ports of `br-v99`.
- `tcpdump -ni br-v99 'arp or icmp'` — see if anything moves.
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

### Symptom: HOME wifi clients get DHCP but no internet

- On the client: `ip route` — default should be `10.97.20.1`
- On the client: `nslookup example.com` — DNS works?
- On BT8-gateway: `tcpdump -ni br-v20 'icmp and src host <client-ip>'`
  while client pings 1.1.1.1 — see the request leave HOME bridge
- On BT8-gateway: `tcpdump -ni br-v99 'icmp and src host <client-ip>'`
  — see it leave on transit
- If the request leaves but no reply: thebeyond's NAT may not be
  matching the source. Check on thebeyond:
  `nft list table inet filter | grep -A2 masquerade`

### Symptom: laptop loses LuCI access mid-config

Check, in order:
1. Did you reconfigure the port your laptop is on? (You shouldn't
   have — `<MGMT>` was supposed to stay in `br-lan`.)
2. Did the laptop's IP change? Renew DHCP: `dhclient -r && dhclient`
   on Linux, or unplug-replug the cable.
3. Try `192.168.1.1` (default lan) and management VLAN IP
   (`10.97.11.1`) — one of them should work.
4. If neither: serial console (next section).

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
