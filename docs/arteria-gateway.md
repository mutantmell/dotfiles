# Arteria: single-port office gateway

`arteria` replaces the routing duties of the office OpenWrt `bt8gw` on the old
Intel NUC BOXNUC7i5BNH previously used by `erebonia`. The Flint 2 provides the
office Ethernet bridge into a new 5 GHz 802.11s/BATMAN mesh on the existing
`bt8bridge`.
`bt8gw` is disconnected during cutover. `thebeyond` remains the Internet gateway
and NAT owner.
There is no NAT on arteria.

The switch's current firmware, management address, and physical port assignments
must be checked on site. Historical switch notes disagree with the registry;
do not apply their management migration as part of this cutover.

## Architecture decision: gateway placement

Use the existing BOXNUC7i5BNH for the initial migration. The intended long-term
home for arteria is a dedicated NixOS gateway microVM on calvard, once calvard
has been prepared as a minimal, locked-down virtualization host. A dedicated
lab firewall appliance is not a planned prerequisite; invest in calvard's
hardware as capacity requires. The NUC can remain available as a recovery
gateway after the VM migration, with its gateway interfaces disconnected while
the VM is active.

Calvard's hypervisor is part of the network security boundary: host compromise
could alter the gateway VM or bypass its policy through host networking.
Application guests must remain isolated, with host-enforced VLAN membership
limited to their required networks. Restrict host administration to designated
operator paths. Calvard maintenance or failure will interrupt office routing
as well as its hosted services; accept that shared failure domain and retain
direct local-console recovery. Thebeyond remains the Internet gateway, NAT
owner, and VPN endpoint.

Run the gateway microVM directly under NixOS/systemd, independently of calvard's
future k3s cluster. Keep its boot artifacts and writable storage local, start
it automatically, and avoid startup dependencies on DNS, PKI, NFS, Kubernetes,
or other services reached through the gateway. Preserve a direct management
path to calvard while its gateway VM is unavailable, including host-to-guest
connectivity through the chosen virtual networking arrangement.

The VM migration is future work, not implemented by this profile. Reuse
`hosts/arteria/router.nix` for routing policy and addresses, adapting the disk,
hardware, and interface bindings to the VM. Test host cold boot, gateway
restart, management access during an outage, and rollback to the NUC before
retiring the physical deployment. Only one deployment may own arteria's
gateway addresses and DHCP/IPv6 services at a time.

## Hardware and installation

The pre-migration `erebonia` hardware configuration (the parent of commit
`362ecdd`) records an Intel x86-64 machine, Intel virtualization, SATA storage,
and the `rtsx_pci_sdmmc` initrd driver. The operator has confirmed the model as
BOXNUC7i5BNH; the historical configuration does not record the NIC MAC or disk
serial. Before the generic uplink rename in commit `c2a553f`, the old
configuration used `eno1` for its Ethernet VLANs. The old deployment used
`/dev/sda`; that is an installation
default, not proof that today's disk has that name.

Before installing, attach a monitor/keyboard and boot a NixOS installer in UEFI
mode. Record:

```sh
lsblk -o NAME,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/
ip -br link
lspci -nnk
```

Back up anything still needed from the old erebonia installation. Confirm the
installation disk and the physical NIC before running disko or an installer.
The host uses a persistent ext4 root and EFI boot partition, with no disk
encryption or impermanence, so it can recover unattended after power loss.

The onboard PCI Ethernet NIC is renamed `uplink` by a networkd link rule.
Verify its udev `ID_PATH` starts with `pci-` and that there is only one matching
physical Ethernet NIC:

```sh
udevadm info --query=property --path=/sys/class/net/YOUR_ETHERNET_INTERFACE
```

If the device has multiple matching PCI Ethernet NICs, narrow the link rule in
`hosts/arteria` to the observed path or permanent MAC before installation.
USB Ethernet is not required. No untagged address or DHCP client is configured
on `uplink`; an ordinary untagged laptop cable will not reach the running host.

Build the host from the repository:

```sh
nix build .#nixosConfigurations.arteria.config.system.build.toplevel
```

Install from the local console using the repository's disko configuration after
confirming its disk selection. If necessary, change the disk device in
`hosts/arteria/disk.nix` to the verified `/dev/disk/by-id/` path before building
the installer script. Copy the flake to the installer and, from its directory,
build the pinned partitioning script:

```sh
nix build .#nixosConfigurations.arteria.config.system.build.diskoScript \
  --out-link /tmp/arteria-disko
```

Inspect the script and confirm its device matches the intended disk. The next
command erases that disk, creates the filesystems, and mounts them under `/mnt`:

```sh
sudo /tmp/arteria-disko
```

Then install the host:

```sh
nixos-install --flake .#arteria
```

Partitioning erases the selected disk. Do not reuse erebonia's old VM-host
configuration, secret files, or storage mounts for this installation. Reboot
with console access available, and confirm `ip -br link` shows `uplink`.
Set a root password when `nixos-install` prompts; this persistent host retains
that password for physical-console recovery. SSH password authentication is
disabled; remote administration uses the configured public keys/certificates.

## One Ethernet port, several networks

Connect arteria to a tagged switch port. Linux creates one VLAN interface per
office network, so the same wire carries downstream networks and upstream
transit without mixing their Layer-2 broadcast domains.

| VLAN | Purpose                             | Arteria IPv4 address |
| ---- | ----------------------------------- | -------------------- |
| 11   | Office management                   | `10.97.11.1/24`      |
| 12   | Office network-equipment management | `10.97.12.1/24`      |
| 20   | Trusted clients                     | `10.97.20.1/24`      |
| 21   | Lab                                 | `10.97.21.1/24`      |
| 50   | Applications                        | `10.97.50.1/24`      |
| 51   | Isolated dev-machine cluster        | `10.97.51.1/24`      |
| 255  | Transit to thebeyond                | `10.255.255.2/30`    |

IPv6 addresses are derived from the central registry, including its group-1
ULA prefixes. The transit default gateways are `10.255.255.1` and
`fdc6:55f2:0a5e:ffff::1`. The registry's `bt8gw` address-space key remains to keep
addresses stable; it no longer implies that the gateway hardware is a BT8.

IPv4 DHCP runs on VLANs 20, 21, 50, and 51, with the existing sixteen dev-slot
MAC/IP reservations on VLAN 51. VLANs 11 and 12 use static IPv4 addresses.
IPv6 RA/DNS runs on all six office VLANs; APP/50 uses stateful DHCPv6 as recorded
in the gateway reference, while the others use SLAAC. Confirm the live network's
IPv6 expectations before cutover. Arteria's SSH accepts the configured operator
keys from management/trusted/lab and the operator VPN, not from cluster or APP.

## Gateway policy to review

This profile translates the documented intended flows into router6 policy;
it is not a dump of the live fw4 rules. In particular, it replaces the old
documented broad APP-to-management and transit-to-APP accepts with explicit
service flows. Verify application behavior before accepting the cutover.

| Source                   | Permitted destinations                                                        |
| ------------------------ | ----------------------------------------------------------------------------- |
| Management               | Trusted, APP, netmgmt, and transit                                            |
| Trusted                  | Management, lab, APP, netmgmt, and transit                                    |
| Lab                      | Management, APP, cluster, and transit                                         |
| APP                      | Transit; basel TCP 443; tharbad TCP 3100/8427; oracion to messeldam TCP 3890  |
| Cluster                  | Creil TCP 22/443; zeiss TCP 443; public Internet over transit                 |
| Netmgmt                  | Gateway DNS and ping; no forwarded egress                                     |
| Operator VPN via transit | Office VLANs and gateway SSH                                                  |
| DMZ via transit          | Basel TCP 443; tharbad TCP 3100/8427; creil TCP 22/443; zeiss/oracion TCP 443 |
| Media VPN via transit    | Oracion TCP 443                                                               |

Thebeyond continues to enforce its own policy on transit traffic. A permission
on arteria does not bypass that upstream firewall. Established replies are
allowed. Cluster transit rejects private IPv4 and ULA/link-local IPv6 targets,
preventing the default route from bypassing local isolation. The retired
`saint-arkh → roer` rule in historical notes is not reproduced: roer is not a
current registry host. If a still-used flow is missing, resolve it explicitly
before deployment rather than opening a whole zone pair.

VLANs 10, 30, 31, 40, 41, and 100 remain owned by thebeyond. Arteria does not
need interfaces for them. Keep them on the OpenWrt-to-switch trunk wherever
there are local consumers. Gaming/IoT SSIDs and Ethernet access ports still
attach to their respective VLANs; moving the gateway does not flatten them.

The NUC's gigabit link carries aggregate routed traffic. Traffic between VLANs
may cross that wire in both directions; traffic within a VLAN normally stays
on the switch. Do not expect the temporary gateway to provide 10 Gb/s routing.

## Switch port plan

Choose free ports based on actual wiring. These are roles, not prescribed
physical numbers; existing notes sometimes assume `lan1`, but that is not a
verified inventory.

| Role                     | Tagged VLANs                             | Untagged/PVID                             |
| ------------------------ | ---------------------------------------- | ----------------------------------------- |
| Arteria NIC              | 11, 12, 20, 21, 50, 51, 255              | None; no native client network            |
| Office Flint 2 bridge    | Existing required fabric VLANs, plus 255 | Preserve any verified current requirement |
| VM/server host trunks    | Only VLANs required by that host         | Preserve existing host configuration      |
| Operator recovery laptop | None                                     | 11                                        |
| Wired trusted client     | None                                     | 20                                        |
| Gaming console           | None                                     | 41, if the console uses the gaming VLAN   |
| Wired IoT device         | None                                     | 40                                        |

Access ports have exactly one untagged/PVID VLAN and no unrelated tagged
memberships. Arteria's trunk must not have a native VLAN that puts untagged
clients into a privileged network. Preserve existing PoE settings and the
switch management interface throughout this change.

VLAN 255 is especially important: older switch examples omit it because transit
previously terminated inside the BT8. Now it must cross the switch from the
OpenWrt bridge to arteria. End-user ports must not be members of VLAN 255.

## Managing the OpenWrt switch through LuCI

These instructions assume the GS1900-10HP runs OpenWrt. If it runs Zyxel OEM
firmware, use its VLAN membership/PVID controls instead; do not paste UCI
commands into it. Identify the installed firmware before proceeding.

1. Log in through the currently working management address. The central
   registry records `arseille` at `10.91.10.12` on VLAN 10; older notes also
   describe `10.97.12.12` on VLAN 12. Treat neither as verified live state.
2. Under **System → Backup / Flash Firmware**, download a configuration backup.
   Save it privately outside the repository. Keep local console access to the
   NUC and a separate working connection to the switch.
3. Record the current physical peers, bridge, management interface, VLAN table,
   and PoE configuration. Useful read-only commands on the switch are:

   ```sh
   ubus call system board
   ip -br address
   uci show network
   bridge vlan show
   ip route show
   ```

4. Open **Network → Interfaces → Devices**, configure the existing bridge
   (`switch` or `br-lan`), and open **Bridge VLAN filtering**. Keep its name and
   existing membership. If this firmware uses a different switch model/menu,
   stop and adapt the instructions to the observed device configuration.
5. Add the arteria port as **tagged** in rows 11, 12, 20, 21, 50, 51, and 255.
   Remove untagged/PVID membership from that port. Preserve existing host ports
   and the currently working management path.
6. Add VLAN 255 as tagged on the office OpenWrt uplink too. Preserve the other
   fabric VLANs needed by existing clients. The switch does not run BATMAN:
   this uplink must carry conventional 802.1Q frames, not BATMAN encapsulation.
7. Make a spare operator port **untagged + primary/PVID** on VLAN 11. Remove its
   membership in other VLANs. This reaches arteria without the wireless link.
   If the switch itself is managed on another VLAN, retain a second access port
   on that VLAN for direct switch recovery.
8. Keep the **Local** checkbox enabled for the switch's existing management
   VLAN. Transit and forwarding-only VLANs do not need local termination on
   the switch CPU. Do not add a switch IP, DHCP server, or router advertisement
   on VLAN 255.
9. Use **Save & Apply** with LuCI's confirmation/rollback mechanism. Confirm
   from a second session that the old switch management path still works.
   Re-read `bridge vlan show` and verify membership before connecting arteria.

Switch management remains independent of the gateway hostname. If it currently
uses VLAN 12 with gateway `10.97.12.1`, that address moves to arteria. If it uses
VLAN 10 with gateway `10.91.10.1`, keep that arrangement for this cutover; direct
access from a laptop on a VLAN-10 access port with `10.91.10.2/24` avoids any
cross-gateway firewall dependency. Cross-VLAN access to the old VLAN-10 switch
address is not guaranteed by thebeyond's existing firewall. Do not change the
switch IP, registry entry, or default route as an incidental fix.

## OpenWrt bridge requirements

The office Flint 2 must expose a normal tagged Ethernet trunk to the
switch. For each VLAN with a wired consumer, bridge its `bat0.<vid>` interface
to the corresponding tagged Ethernet/bridge-VLAN interface. In particular,
`bat0.255` must reach switch VLAN 255. Arteria's seven VLANs must reach the switch
while arteria owns their gateway addresses. The Flint 2 must not run gateway
DHCP/DHCPv6/RA services on those bridged networks.

The planned path is:

```text
arteria -- tagged Ethernet/switch -- Flint 2
                                      |
                               5 GHz 802.11s/BATMAN
                                      |
                                  bt8bridge -- existing wired fabric -- thebeyond
```

The NUC's Ethernet trunk can also connect directly to a configured Flint 2
trunk port; the switch port plan applies wherever the office switch joins
that same tagged fabric. Arteria always receives ordinary 802.1Q Ethernet.

Configure matching mesh ID, encryption credentials, 5 GHz channel/channel
width, and BATMAN routing algorithm on the Flint 2 and `bt8bridge`. A matching
SSID alone does not establish a BATMAN path. On `bt8bridge`, ensure the new
mesh reaches the existing BATMAN fabric and VLAN 255's wired path to thebeyond.
If using a separate BATMAN interface for the new mesh, explicitly connect the
required VLANs into the existing wired fabric and avoid duplicate L2 paths.

Intermediate BATMAN nodes need no per-VLAN termination. The conversion to a
normal Ethernet trunk happens at the office node, not in the switch or NUC.
Prepare the Flint 2 and the new mesh on `bt8bridge` before the cutover, keeping
arteria's gateway/DHCP/RA interfaces isolated until BT8GW is disconnected.
Retain the old mesh configuration for rollback.

## Gateway cutover

1. Back up the BT8 gateway configuration. Capture its current DHCP reservations,
   advertised DNS/IPv6 settings, and effective firewall policy privately. Check
   the arteria configuration against these before changing ownership. The old
   as-built notes do not capture every live rule, so an evaluated flake is not
   proof of equivalent production behavior.
2. Install/test arteria on an isolated switch or disconnected trunk. It claims
   the same gateway addresses and serves DHCP/RA; do not connect it to live
   office VLANs while BT8-gateway still owns those roles.
3. Prepare switch trunks and recovery ports. Prove switch access from its direct
   management port. Put the operator laptop on VLAN 11 with `10.97.11.2/24` for
   direct arteria access during cutover; no DNS or default route is needed.
4. Disconnect `bt8gw` completely from the live fabric. Power it off or disable
   its mesh radio as well as disconnecting Ethernet: an active wireless link
   could still advertise its old gateway addresses and DHCP/RA services.
   Keep its saved configuration intact for rollback.
5. Bring up the Flint 2's new 5 GHz mesh link to `bt8bridge`, verify BATMAN
   neighbor/originator visibility, and connect arteria's trunk through the
   Flint 2/switch tagged fabric. Verify direct SSH at `10.97.11.1`, then transit
   and local routing. The Flint 2 provides L2 transport; arteria is the only
   office gateway/DHCP/RA owner.
6. Renew client leases or reconnect them so obsolete DNS/RA state does not mask
   a problem. Check both IPv4 and IPv6. Some live OpenWrt details are being
   replaced by explicit desired policy, not copied blindly.
7. Reboot arteria with local console access, confirm recovery, then retain the
   BT8 backup and previous arrangement until the new gateway has proved stable.

On arteria:

```sh
networkctl status uplink
ip -br address
ip route show
ip -6 route show
ping -c 3 10.255.255.1
ping -6 -c 3 fdc6:55f2:0a5e:ffff::1
systemctl --failed
nft list ruleset
```

From representative clients, verify DHCP, internal DNS, permitted application
flows, Internet access, and forbidden cross-zone flows. In particular, a
VLAN-51 dev machine must reach creil on 22/443 and zeiss on 443 while being
denied other application hosts and management/trusted/lab/netmgmt networks.
Verify office administration, monitoring, and any VPN ingress actually used.
IPv6 must enforce the same isolation as IPv4. Check gaming/IoT VLAN isolation
independently; those networks still use thebeyond as their gateway.

If transit fails, inspect switch VLAN 255 and the OpenWrt `bat0.255` bridge
before changing routes. Thebeyond already routes the office address space via
`10.255.255.2` and `fdc6:55f2:0a5e:ffff::2`; its nexthops remain unchanged.

## Rollback

Disconnect arteria's trunk first, isolate the Flint 2 path if necessary, then
reconnect `bt8gw` using its original mesh and saved configuration. Restore its
gateway/DHCP/RA settings only if they were changed. Verify the original
path before reconnecting clients. Never run both gateway configurations on the
same VLAN simultaneously. Restore the switch backup only if its changes broke
the original path; the new spare arteria/recovery memberships can otherwise
remain unused.

On arteria, use its local console to select the previous NixOS generation or
run `nixos-rebuild switch --rollback`. Remote rollback cannot repair missing
switch VLAN membership. Future gateway updates should retain a working local
console/recovery port and be separate from OpenWrt firmware or mesh changes.

## Backhaul validation

Use 5 GHz for the initial Flint 2-to-BT8Bridge backhaul. WiFi 7 client support,
6 GHz backhaul, and multi-link backhaul are separate capabilities; do not infer
mesh reliability from a device's WiFi generation or AP-mode feature list.
OpenWrt's [802.11s documentation](https://openwrt.org/docs/guide-user/network/wifi/mesh/802-11s)
makes working mesh support dependent on the hardware and driver.

Closed doors may weaken an already marginal wireless path. Six GHz experiences
greater attenuation through obstacles, although its free-space propagation
difference from 5 GHz is modest. This is a possible contributor to the
apartment's reported problems, not a confirmed diagnosis. See
[Cisco's 6 GHz deployment guidance](https://www.cisco.com/c/en/us/td/docs/wireless/controller/9800/technical-reference/c9800-best-practices.html).

Compare local throughput, packet loss, and latency with doors open and closed.
Use a client wired to the remote node to isolate backhaul performance from the
client WiFi link. Keep node placement fixed when comparing bands. Validate the
mesh at its intended positions before purchasing additional APs or depending
on a 6 GHz backhaul.

## Later OpenWISP management

OpenWISP is deferred until calvard has a separate trusted infrastructure k3s
cluster and the gateway and mesh are stable. It is not deployed or required by
this profile; do not deploy it in erebonia's CI/development cluster. Its device
management credentials belong in the trusted infrastructure environment, with
explicitly permitted access to AP management addresses. Cluster bootstrap,
network policy, and OpenWISP deployment are future work.
For two or three APs and a switch, evaluate whether centralized configuration
and update tracking save more effort than maintaining the controller services.
Keep direct SSH/LuCI access and operator recovery independent of the controller.

### Separate firmware from configuration

Build a pinned upstream OpenWrt sysupgrade image per hardware model with the
required packages: hardware drivers/firmware, `kmod-batman-adv`, `batctl-full`,
a mesh-capable `wpad` variant, and `openwisp-config` if enrolling the device.
Include the monitoring agent if used. The resulting image can be shared by
devices of that model; full per-device SSID/VLAN/mesh configuration does not
need to be embedded in every firmware build.

The OpenWISP agent still needs a controller URL, registration credentials,
certificate trust, and network connectivity. Provision these during initial
Ethernet enrollment, then let OpenWISP apply the operational mesh, SSID, VLAN,
and management configuration. A mesh-only device cannot fetch its first mesh
configuration over a mesh it has not joined. Factory resets and upgrades that
cannot preserve compatible configuration require the bootstrap path again.
See [agent setup](https://openwisp.io/docs/26.09/openwrt-config-agent/user/quickstart.html)
and [registration](https://openwisp.io/docs/26.09/openwrt-config-agent/user/automatic-registration.html).

Define which settings OpenWISP owns before enrolling a device. Avoid competing
flake scripts and controller templates overwriting the same settings. Retain
recovery configurations and image/package definitions in Git, with secrets
outside plaintext repository files. Prove operation with the controller offline
and manual management with the agent disabled during the pilot.

OpenWISP applies configuration and can restore a backup when its connectivity
test fails. The default test checks controller reachability; it does not prove
BATMAN transit, every VLAN, or client isolation. Add appropriate operational
checks where needed. Configuration rollback does not provide firmware rollback.
See [configuration testing](https://openwisp.io/docs/26.09/openwrt-config-agent/user/settings.html).

### Updates across critical network devices

OpenWISP uploads an image before starting sysupgrade, then waits and retries
connecting after the device reboots. A temporary outage is expected. Preserve
the compatible local mesh/management configuration during routine upgrades and
include every required package in the replacement image. Each node must be able
to rejoin the network without first fetching configuration from the controller.
Verify those properties with a single-device trial before routine rollouts.
See [upgrader options](https://github.com/openwisp/openwisp-firmware-upgrader/blob/master/openwisp_firmware_upgrader/upgraders/openwrt.py)
and [reconnection settings](https://openwisp.io/docs/26.09/firmware-upgrader/user/settings.html).

Use explicit single-device upgrades at this scale:

1. Upgrade peripheral APs individually; verify mesh membership, management,
   client connectivity, and VLAN isolation before proceeding.
2. Upgrade the Flint 2 and BT8Bridge separately. Each is critical to the office
   path; accept a maintenance outage and verify recovery before the next update.
3. Upgrade the switch in a separate window, accounting for management paths and
   any APs it powers. Keep direct recovery access available.

The documented [batch upgrade workflow](https://openwisp.io/docs/26.09/firmware-upgrader/user/quickstart.html)
allows device selection and grouping; do not assume it orders upgrades around
mesh dependencies or waits for all affected clients to recover. Controller
workers must remain running even if their network path to a device disappears.
Keep the controller's own cluster updates separate from network-device updates.

If a device does not return, OpenWISP can report failure but cannot repair the
broken management path remotely. Use wired/console recovery or the device's
supported recovery procedure; do not assume automatic firmware rollback.
[Upgrade status documentation](https://openwisp.io/docs/26.09/firmware-upgrader/user/upgrade-status.html)
describes post-flash failures and recovery investigation.
