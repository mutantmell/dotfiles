# KVM over IP for a 4-machine homelab under $600

**Four JetKVM units at $69 each ($276 total) represent the best value for your setup**, delivering full BIOS-level keyboard, video, and mouse access to all four machines simultaneously with modern HDMI, 1080p@60fps streaming, and zero NixOS compatibility issues. For those willing to spend more, a PiKVM V4 Plus paired with the new PiKVM Switch Multiport Extender (~$555–675) offers the most mature open-source ecosystem with integrated per-port ATX power control. Enterprise multi-port KVM switches from Aten, Raritan, and Vertiv are all well over $1,000 new, but used units on eBay can fit the budget — if you're willing to accept VGA-era adapters and aging firmware.

The landscape has shifted dramatically since 2023. Sub-$100 open-source devices like JetKVM and GL.iNet Comet have made dedicated per-machine KVM over IP economically viable for homelabs, eliminating the need to choose between a single expensive enterprise switch or awkward DIY compromises. Every modern option uses HTML5/WebRTC browser interfaces — no Java applets, no agents on managed machines, no NixOS headaches.

## Four approaches that fit your $300–600 budget

Each strategy below provides full remote KVM including BIOS/UEFI access, virtual media for OS installs, and browser-based control from any NixOS or Linux desktop.

**Approach 1: 4× JetKVM — $276 + adapters (~$310 total).** The crowd favorite. Each $69 unit handles one machine with 1080p@60fps H.264 video at 30–60ms latency. Fully open-source Go/TypeScript software. JetKVM Cloud provides a free multi-device dashboard via WebRTC, or you can skip the cloud entirely and use Tailscale. ATX power control is available as a ~$15–20 extension module per unit. The only downsides: 100Mbps Ethernet only, mini-HDMI connector (adapter may be needed for some NUCs), and the software ecosystem is younger than PiKVM's. Jeff Geerling called it "one of the nicest homelab devices I've seen."

**Approach 2: PiKVM V4 Plus + PiKVM Switch — ~$555–675.** The premium open-source option. One PiKVM V4 Plus ($280–400 depending on retailer) paired with one PiKVM Switch Multiport Extender (~$275) gives you 4 HDMI+USB+ATX ports managed through a single, polished web interface. The Switch is plug-and-play, includes per-port ATX control cables, dedicated EDID emulation per port, and HDMI dummy plugs for fast switching. The trade-off is you can only view **one machine at a time** (though ATX status/controls show for all four simultaneously). PiKVM's software earns an **A+ security rating** from independent auditors, has the largest community, and supports ISO mounting, VNC, IPMI/BMC protocols, and two-factor authentication. Expandable to 20 ports by daisy-chaining five Switches. The V4 Mini ($270) is **not compatible** with the Switch due to missing USB host ports — you must get the V4 Plus.

**Approach 3: Used enterprise KVM switch — $200–450.** Avocent MergePoint Unity MPU2016 units (16-port) sell for under $100 on eBay. Add four MPUIQ-VMCHS cables at $40–60 each and you're looking at $220–360 total. Similarly, Raritan Dominion KX III DKX3-108 (8-port) units go for $40–200 used, plus CIM dongles at $40–75 each. Both support HTML5 web interfaces on newer firmware. The catch: most enterprise CIM dongles use VGA, and your NUCs output HDMI — you'll need HDMI-to-VGA adapters, adding cost and signal-quality concerns. Older firmware may still require Java. Enterprise switches are also physically large (1–2U rackmount) and consume more power than the alternatives. Best for those who already have a proper rack and want maximum ports for future expansion.

**Approach 4: PiKVM V4 Mini + third-party KVM switch — ~$330–350.** A budget PiKVM path: one V4 Mini ($270) controlling four machines through a TESmart or ezcoo 4-port HDMI KVM switch ($60–80). PiKVM has documented multiport configuration for these switches via GPIO hotkey control. This works but requires YAML configuration, may have EDID quirks, and lacks per-port ATX power control. It's a popular setup covered by TechnoTim and others, but the official PiKVM Switch is more reliable and polished.

## The single-port device landscape in early 2026

| Device                  | Price     | Resolution  | Latency | Virtual media | ATX control    | Open source                      | Network                   |
| ----------------------- | --------- | ----------- | ------- | ------------- | -------------- | -------------------------------- | ------------------------- |
| **JetKVM**              | $69       | 1080p@60fps | 30–60ms | Yes           | Extension ~$20 | Yes (Go/TS)                      | 100Mbps                   |
| **GL.iNet Comet**       | $89       | 2K@60fps    | 30–60ms | Yes           | Extension      | Yes (PiKVM-based)                | Gigabit                   |
| **BliKVM v4**           | ~$100–150 | 1080p       | ~100ms  | Yes           | Included       | Yes (PiKVM-based)                | 100Mbps PoE               |
| **PiKVM V4 Mini**       | ~$270     | 1080p@60Hz  | ~100ms  | Yes           | Included       | Yes                              | Gigabit + WiFi            |
| **PiKVM V4 Plus**       | ~$280–400 | 1080p@60Hz  | ~100ms  | Yes           | Included       | Yes                              | Gigabit + WiFi + LTE slot |
| **TinyPilot Voyager 3** | $399      | 1080p@60Hz  | ~140ms  | Yes (Pro)     | No             | Community: MIT; Pro: proprietary | Dual Gigabit + WiFi       |
| **NanoKVM**             | ~$25–50   | 1080p       | ~100ms  | Limited       | Via board      | Partially                        | 100Mbps                   |

**NanoKVM deserves a special warning.** Despite its tempting $25–50 price, independent security audits found hardcoded root credentials, an undisclosed hardware microphone, passwords stored with a hardcoded AES key, and pre-installed network attack tools (tcpdump, aircrack). It received an **F security rating**. Avoid it on any network with sensitive data.

**TinyPilot** remains a polished commercial product at $399 per unit, but at that price, four units would cost $1,600 — far beyond budget. It targets MSPs and enterprises rather than homelabs. The company is active and shipping but charges for features like authentication and virtual media through its Pro license.

**GL.iNet Comet** ($89) is an interesting middle ground — it runs PiKVM-derived software, has Gigabit Ethernet and 2K video capture, and was positively reviewed by ServeTheHome. Some privacy-conscious users flagged phone-home behavior in the firmware, though this can be blocked via firewall rules.

## No unified dashboard exists yet, but workarounds abound

The single biggest gap in the multi-unit KVM over IP space is **fleet management**. No widely-adopted open-source dashboard aggregates multiple PiKVM or JetKVM units into one interface. PiKVM has an open GitHub feature request (#854, filed November 2022) for centralized management, but it remains unimplemented.

Current workarounds rank from simplest to most involved. **JetKVM Cloud** is the closest to a real dashboard — it shows all your cloud-registered JetKVM units in one web interface with WebRTC access to each. It's free, optional, and peer-to-peer encrypted, but it does route through JetKVM's STUN/TURN servers. For the privacy-conscious, **Tailscale** (supported natively by both PiKVM and JetKVM) lets you access each device on a private mesh network; a simple homepage dashboard like Homer or Homarr with links to each device's local IP is the most common community setup. PiKVM's comprehensive **REST API** enables custom scripting — you can build power-cycle automations, take screenshots, and send keystrokes programmatically across a fleet. A community-built **Grafana dashboard** (ID 21674) aggregates PiKVM health metrics via node_exporter, though it provides monitoring rather than interactive control.

Notably, **Apache Guacamole does not work well with PiKVM**. PiKVM's VNC server uses VeNCrypt with JPEG compression, and Guacamole's VeNCrypt implementation is incomplete. Multiple GitHub issues (PiKVM #518, #1447; Guacamole GUACAMOLE-1450) confirm this incompatibility. Guacamole is better suited for aggregating RDP/SSH/VNC to machines that are already booted, not for hardware-level KVM access.

## NixOS works flawlessly on both sides of the connection

Hardware KVM over IP is **completely OS-agnostic by design**. The managed machine sees a standard HDMI monitor and USB keyboard/mouse — no drivers, no agents, no software of any kind is needed on your NixOS NAS or NUCs. This works at every level: BIOS/UEFI setup, boot loader (GRUB), NixOS installer, crashed/frozen systems, and even bare metal with no OS installed.

On the **client side** (the machine you use to access the KVM), every modern solution uses HTML5 web interfaces. Firefox or Chromium on NixOS works perfectly. No Java applets, no Flash, no browser plugins. WebRTC for H.264 streaming is supported in all modern browsers. If you prefer VNC, `tigervnc` is packaged in nixpkgs and works with PiKVM's VNC server. The `ipmitool` package is also available for IPMI protocol access to PiKVM devices.

One practical NixOS tip: consider configuring **serial console access** as a complement to your KVM over IP. Adding `console=ttyS0,115200n8` to your kernel parameters and enabling a serial getty gives you a text-mode backup channel. PiKVM V4 Plus has a Cisco-style RJ-45 serial port, and JetKVM supports serial via its RJ11 extension — either can provide serial console access alongside HDMI video. For NixOS specifically, serial console is useful during `nixos-rebuild switch` operations where the display may briefly blank.

The only NixOS-specific concern involves **older enterprise KVM switches**. Pre-2018 Raritan and Avocent units that still require Java applets for their remote console would be problematic on NixOS, where Java browser plugin support is essentially nonexistent. Stick with devices that offer HTML5 interfaces — all current-generation products do.

## Conclusion: what to buy for your specific setup

For a NAS running NixOS and 2–3 Intel NUCs, **4× JetKVM at $276 total is the clear winner** within the $300–600 budget. Each NUC and the NAS gets its own dedicated, always-available out-of-band access with no single point of failure. You can access all four machines simultaneously in separate browser tabs. The open-source software, low latency, and JetKVM Cloud dashboard check every box. Add ATX power control extensions (~$80 for four) if you want remote power cycling, though Wake-on-LAN may suffice for the NUCs.

If you value software maturity and security above all else, the **PiKVM V4 Plus + PiKVM Switch at ~$555–675** is the premium choice. It has the most battle-tested codebase, the best security audit results, integrated ATX control on all four ports, and a clear upgrade path to 20 machines. The trade-off — viewing only one machine at a time — matters less than you might expect in practice, since active troubleshooting sessions rarely span all four machines simultaneously.

Skip the used enterprise switches unless you specifically need more than 8 ports or already own compatible CIM dongles. The adapter headaches and aging firmware aren't worth the savings when purpose-built homelab devices now exist at this price point.

## Addendum

The PiKVM might have some additional features worth mentioning, like simpler ways to upload installer images to machines in the case of some sort of catastropic failure. That would align well with our nixos-anywhere-aligned approach to deploying, and also provides a good way to recover devices that rely on netboot, in case they get corrupted somehow.
