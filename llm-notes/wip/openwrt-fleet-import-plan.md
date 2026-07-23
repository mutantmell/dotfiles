# OpenWrt Fleet Import and Rotation Plan

**Status:** WIP; discovery has not started.
**Plan date:** 2026-07-23.
**Scope:** Import `bt8gw`, `bt8bridge`, the spare ASUS ZenWiFi BT8, and the
ZyXEL GS1900-10HP into this flake without combining unrelated device cutovers
or losing the current rollback paths.
**Related:**
[`dual-gateway-followups-plan.md`](./dual-gateway-followups-plan.md) B.1-B.3 and
D.2 identify the earlier BT8 and switch work. This plan is the concrete
execution plan for those items. The as-built references remain
[`bt8-gateway-as-built.md`](../guides/bt8-gateway-as-built.md),
[`bt8-gateway-luci-runbook.md`](../guides/bt8-gateway-luci-runbook.md), and
[`bt8-bridge-luci-runbook.md`](../guides/bt8-bridge-luci-runbook.md).

## Ownership legend

- **[Operator]** requires physical access, secret access, observation of live
  behavior, or approval of a disruptive/irreversible action. An LLM must not
  perform it autonomously.
- **[LLM analysis]** requires interpretation of live captures, comparison with
  the registry/as-built notes, or derivation of intended policy. It requires an
  LLM working with operator-supplied evidence; its output must be reviewed.
- **[Implementation]** is ordinary repository work that an operator or coding
  agent can perform after the preceding decisions are approved.
- **[Operator + LLM]** is an explicit review gate: the LLM prepares the
  evidence and proposed disposition; the operator confirms that it represents
  the intended network.

No live device change is authorized merely by completing repository work in
this plan. Each deployment has its own operator gate.

## Goals and non-goals

Goals:

1. Make the flake the reviewed source of truth for all four devices.
2. Replace the two active BT8 roles one at a time by rotating through the spare,
   preserving a known-good physical rollback device at each cutover.
3. Move the Batman wireless backhaul to a proven 80 MHz configuration and
   rotate its credential during the bridge transition.
4. Derive the BT8 gateway firewall, DHCP/RA, VLAN, and management policy from
   the network registry and explicit exceptions rather than copying ad-hoc UCI.
5. Migrate the GS1900-10HP independently with make-before-break management
   access and an explicit PoE policy.
6. Produce exact build, deployment, verification, and recovery procedures for
   each hardware type.

Non-goals for the initial import:

- Do not introduce `mesh11sd`. It owns HWMP behavior that conflicts with the
  `mesh_fwding=0` underlay required by batman-adv.
- Do not build a custom dynamic channel-selection daemon. First establish a
  stable, declaratively shared channel and collect evidence that automation is
  worthwhile.
- Do not enable DFS channels during the initial backhaul qualification.
- Do not migrate the switch in the same maintenance window as either BT8 role.
- Do not tighten firewall policy and replace gateway hardware as an
  unreviewable single change. The desired image can contain both, but the
  policy delta must be tested independently before the physical cutover.

## Invariants and stop conditions

These apply throughout the plan:

- Only one production role changes at a time.
- A current encrypted backup, a tested recovery method, and a known-good
  previous device/image must exist before each change.
- The operator must have a control path that does not depend on the interface
  being modified: serial console, direct recovery port, or a physically
  swappable previous device as appropriate.
- Raw device backups and captures are sensitive and must never be committed.
- A generated image is deployed with clean configuration (`sysupgrade -n`);
  retained writable state must not be relied upon to complete an incomplete
  model.
- If a gate fails, stop and restore the immediately preceding known-good state.
  Do not continue to the next device to work around a failed migration.
- Use MHz for channel width (`80 MHz`, `160 MHz`), not GHz.

## Phase 0: Prepare the evidence workspace and rollback inventory

- [ ] **[Implementation]** Add a repository ignore rule for a local capture
      directory such as `temp/openwrt-import/`, if the existing ignore rules do
      not already cover it.
- [ ] **[Operator]** Create encrypted off-repository storage for raw backups and
      record the location in the operator's private notes.
- [ ] **[Operator]** Inventory for every device:
  - exact model and hardware revision;
  - current OpenWrt version and image source;
  - MAC addresses and physical port labels;
  - current management addresses and reachable source VLANs;
  - console, failsafe, TFTP, U-Boot, and physical reset recovery methods;
  - current firmware image and known-good restoration instructions;
  - which cables must be moved to restore the old device.
- [ ] **[Operator]** Photograph and label current cabling before moving any
      device. Record BT8 WAN/LAN port mappings and every GS1900 port's peer.
- [ ] **[Operator]** Confirm that the spare BT8 boots and that its factory
      identity, calibration partitions, Ethernet MACs, and radio MACs can be
      backed up before installing ubootmod.
- [ ] **[Operator + LLM] Gate 0** Review the recovery inventory. Do not begin
      ubootmod or switch VLAN work until every device has a credible recovery
      route.

## Phase 1: Capture live state

### 1.1 Common capture

- [ ] **[Operator]** Create a `sysupgrade -b` archive for each active device and
      store the unmodified archive only in encrypted off-repository storage.
- [ ] **[Operator]** Place text captures under the ignored local directory, one
      directory per device. Capture at minimum:

  ```sh
  uci export
  ubus call system board
  ubus call system info
  opkg list-installed 2>/dev/null || apk list --installed
  ip -details link show
  ip -details address show
  ip route show table all
  ip -6 route show table all
  bridge -details link show
  bridge -details vlan show
  nft list ruleset
  fw4 print
  logread
  dmesg
  ```

- [ ] **[Operator]** Replace secret *values* in the analysis copies with unique
      typed placeholders such as `<REDACTED:batman-mesh-key>` or
      `<REDACTED:wg-private-key>`. Do not delete the option, section, or path.
      Treat the scrubbed capture as sensitive despite the replacements.
- [ ] **[Operator]** Record the time, device uptime, whether the network was
      healthy, and any known transient condition alongside each capture.

### 1.2 BT8-specific evidence

- [ ] **[Operator]** On both active BT8s, capture:

  ```sh
  iw dev
  iw phy
  iw reg get
  iwinfo
  batctl -v
  batctl if
  batctl o
  batctl n
  batctl tg
  ```

  Record unsupported `batctl` commands rather than treating them as a capture
  failure.
- [ ] **[Operator]** Capture at least one healthy sample and, if the failure can
      be observed without inducing it, one degraded sample containing `logread`,
      `dmesg`, station state, Batman neighbors/originators, channel, noise,
      signal, retry rate, and representative throughput/packet loss.
- [ ] **[Operator]** Record the exact primary channel, center frequencies,
      channel width, regulatory domain, DFS events, mesh encryption, mesh ID,
      `mesh_fwding`, MTU, Batman routing algorithm, and every VLAN carried on
      `bat0`.

### 1.3 GS1900-specific evidence

- [ ] **[Operator]** Capture the board identity, boot log, partition layout,
      DSA port names, PoE-related packages, UCI, ubus objects, sysfs objects,
      and per-port PoE status. Commands may include:

  ```sh
  ubus call system board
  ubus list | grep -i poe
  ubus call poe info
  ls -l /sys/class/net
  cat /proc/mtd
  ```

- [ ] **[Operator]** From an allowed workstation on each relevant VLAN, record
      whether ping, SSH, HTTP, and HTTPS reach the switch. This distinguishes an
      address-placement problem from a service-binding or firewall problem.
- [ ] **[Operator]** Record the current CPU-port membership, PVID, tagged and
      untagged state, and physical recovery port before changing VLAN 20.

## Phase 2: Produce and approve the as-built analysis

- [ ] **[LLM analysis]** Parse each UCI export into a normalized inventory of:
  - hardware/radio identities;
  - network devices, bridges, VLANs, addresses, routes, and MTUs;
  - 802.11s and batman-adv configuration;
  - AP networks and radio settings;
  - DHCP, DHCPv6, RA, and DNS behavior;
  - firewall zones, forwardings, redirects, includes, and rules;
  - management service bindings and source reachability;
  - installed packages and non-UCI files;
  - switch port and PoE state;
  - secret-bearing fields without reproducing secret values.
- [ ] **[LLM analysis]** Compare the live state with:
  - `lib/common/data/network.nix`;
  - `lib/common/data/openwrt.nix`;
  - `hosts/thebeyond/router.nix`;
  - existing OpenWrt profiles and device declarations;
  - the BT8 as-built and migration runbooks;
  - known service-flow requirements documented elsewhere in the repository.
- [ ] **[LLM analysis]** Produce a disposition table for every meaningful live
      setting: `retain`, `derive`, `replace`, `remove`, `secret`, or
      `runtime-generated`. Include the reason and the proposed flake owner.
- [ ] **[LLM analysis]** Produce a contradictions/open-questions report. At
      minimum answer:
  - Which device owns L3 for every VLAN?
  - Which VLANs must cross the Batman trunk?
  - Which current firewall rules correspond to still-required flows?
  - Are unexpected DHCP/RA/DNS servers present?
  - Is `mesh_fwding=0` set everywhere used beneath batman-adv?
  - Is the reported timeout correlated with 160 MHz operation, DFS, driver
    faults, reauthentication, MTU, interference, or Batman behavior?
  - What exactly is wrong about the GS1900 address on VLAN 20: address
    duplication, wrong management VLAN, excessive service exposure, or CPU-port
    membership?
  - Which PoE controller and OpenWrt interface are actually supported?
- [ ] **[Operator + LLM] Gate 1** Review the as-built report and resolve all
      topology ambiguities. The operator approves the intended behavior; the
      current live state is evidence, not automatically the desired state.

## Phase 3: Define desired policy before device modules

- [ ] **[LLM analysis]** Derive a flow matrix for `bt8gw` from registry zones
      and documented consumers. For every permitted flow record source zone or
      hosts, destination zone or hosts, protocol/ports, enforcing router, and
      justification. Record explicit denials and router-local input separately.
- [ ] **[Operator]** Approve the BT8 management allowlist for SSH and LuCI,
      including the operator workstation, emergency access path, and any future
      deployment runner.
- [ ] **[Operator + LLM]** Choose the initial fixed non-DFS backhaul channel
      after reviewing regulatory and survey evidence. Fix width at 80 MHz for
      initial qualification and define one rescue channel.
- [ ] **[Operator]** Choose the final role/name for the third BT8 and whether it
      will initially join production or remain a configured cold/warm spare.
- [ ] **[Operator]** Choose and provision the new mesh credential in the
      OpenWrt secrets file. Never place it in the plan, Nix store, build log, or
      capture directory.
- [ ] **[Operator + LLM]** Approve the GS1900 management design: target VLAN
      (expected to be dedicated `netmgmt`, subject to evidence), address,
      gateway, allowed source hosts, recovery access port, and service-binding
      policy.
- [ ] **[Operator]** Define the intended PoE policy by physical port: disabled,
      automatic 802.3af/at, priority, and any supported budget limit. Do not
      assume the future JetKVM's requirements until its PoE specification is
      available.
- [ ] **[Operator + LLM] Gate 2** Approve the desired-policy document and the
      list of intentional differences from live state.

## Phase 4: Verify upstream hardware and boot support

- [ ] **[LLM analysis]** Verify against the selected OpenWrt release and primary
      upstream sources:
  - exact BT8 target, subtarget, profile, image types, and ubootmod procedure;
  - whether factory calibration/MAC partitions require special preservation;
  - exact GS1900-10HP target, subtarget, profile, sysupgrade layout, U-Boot and
    recovery behavior;
  - current mt76/BT8 802.11s limitations at 80 MHz;
  - GS1900 PoE driver/package behavior and known limitations.
- [ ] **[Implementation]** Add pinned Image Builder metadata only for profiles
      supported by the selected release. Do not manufacture a profile mapping
      based on similar hardware.
- [ ] **[Operator + LLM] Gate 3** Decide separately whether each hardware type
      is safe for full image management. If the GS1900 image path or PoE support
      is not sufficiently proven, retain upstream firmware and manage/test its
      UCI transition separately rather than blocking the BT8 import.

## Phase 5: Implement declarative configurations and tests

- [ ] **[Implementation]** Add a BT8 hardware module with stable hardware
      identity and explicit mapping from physical radios/ports to logical roles.
      Do not depend blindly on `radio0`/`radio1` enumeration.
- [ ] **[Implementation]** Add or extend profiles for:
  - BT8 wireless bridge: wired endpoint plus batman-adv/VLAN carriage;
  - BT8 gateway: per-VLAN L3, DHCP/RA/DNS as approved, structured fw4 policy,
    Batman participation, and optional client APs;
  - GS1900-10HP switch: VLAN-filtering bridge, dedicated management interface,
    management-plane restrictions, and PoE policy if supported.
- [ ] **[Implementation]** Derive addresses, VLANs, DHCP reservations, and
      firewall endpoints from the network registry where the registry is
      authoritative. Keep exceptions explicit and documented.
- [ ] **[Implementation]** Represent mesh ID/key and all AP credentials using
      the existing generalized OpenWrt secrets mechanism.
- [ ] **[Implementation]** Set the wireless underlay to 802.11s with
      `mesh_fwding=0`; attach it as a batman-adv hard interface. Assert this in
      evaluation tests.
- [ ] **[Implementation]** Set the initial backhaul band, 80 MHz width, fixed
      channel, country, MTU, and rescue parameters from shared policy rather
      than repeating literals in device files.
- [ ] **[Implementation]** Add pure evaluation/snapshot tests for:
  - every device evaluation and expected image profile;
  - radio selection and 80 MHz backhaul;
  - `mesh_fwding=0` and Batman membership;
  - every carried VLAN and absence of unapproved VLANs;
  - gateway firewall flow matrix and default-deny behavior;
  - DHCP/RA ownership and absence on bridge-only devices;
  - management address and service exposure;
  - GS1900 port membership and PoE intent;
  - secret paths without secret values.
- [ ] **[LLM analysis]** Compare rendered UCI with the normalized as-built
      snapshots and explain every difference. Update desired policy rather than
      hiding unexplained drift in device-local `extraConfig`.
- [ ] **[Implementation]** Add role-specific post-deployment health checks to
      the existing deployer workflow. `fw4 check` alone is insufficient.
- [ ] **[Implementation]** Run the narrow OpenWrt evaluation checks first, then
      `./scripts/agent-preflight.sh --full` because shared network and deployment
      behavior are in scope.
- [ ] **[Operator + LLM] Gate 4** Review rendered UCI, package manifests,
      secrets map, image hashes, test results, health checks, and per-device
      rollback commands before building production artifacts.

## Phase 6: Qualify the spare as the new `bt8bridge`

- [ ] **[Operator]** Back up the spare's factory partitions, calibration data,
      MAC identities, stock firmware, and boot environment.
- [ ] **[Operator]** Install ubootmod using the verified hardware-specific
      procedure. This is a physical and potentially destructive operator step.
- [ ] **[Operator]** Boot the candidate image isolated from production trunks,
      using a temporary hostname/address that cannot collide with `bt8bridge`.
- [ ] **[Operator + LLM]** Execute the bridge acceptance checklist:
  - radio and Ethernet identities match the hardware mapping;
  - only intended services listen;
  - no DHCP, RA, or routing service is accidentally active;
  - mesh uses the new credential, approved non-DFS channel, and 80 MHz width;
  - `mesh_fwding=0`, expected Batman algorithm, hard interfaces, and MTUs are
    active;
  - every expected VLAN crosses the candidate and no unexpected VLAN does;
  - cold boot, peer-first boot, and portal-first boot converge;
  - sustained bidirectional traffic has acceptable throughput, latency, loss,
    and retry rates;
  - logs show no relevant driver reset, DFS event, rekey failure, or Batman
    neighbor churn.
- [ ] **[Operator]** If the active `bt8gw` cannot temporarily participate in
      old and new credential meshes, schedule a coordinated credential change
      with console/physical rollback. Never leave credentials printed in shell
      history or the repository.
- [ ] **[Operator] Gate 5** Approve the bridge cutover only after qualification.
      Connect the candidate to production, verify the full flow checklist, then
      disconnect the old bridge. Keep the old bridge unchanged and ready to
      recable.
- [ ] **[Operator]** Soak the new bridge for an agreed observation period
      covering ordinary and heavy homelab traffic. Record Batman stability,
      packet loss, retransmissions, channel events, and device logs.
- [ ] **[LLM analysis]** Analyze soak telemetry and decide whether the original
      timeout hypothesis is supported. Do not proceed on unexplained recurring
      outages.
- [ ] **[Operator + LLM] Gate 6** Accept the bridge or restore the old bridge.

## Phase 7: Convert the former bridge into the candidate `bt8gw`

- [ ] **[Operator]** Preserve the former bridge's last known-good image and
      backup before changing its role.
- [ ] **[Implementation]** Build the exact reviewed gateway artifact once and
      record its digest/build ID. Do not rebuild between qualification and
      deployment.
- [ ] **[Operator]** Boot it under a temporary identity in an isolated topology.
      Prevent duplicate WAN clients, DHCP servers, router addresses, and IPv6
      advertisements.
- [ ] **[Operator + LLM]** Test the approved flow matrix, including:
  - WAN acquisition, NAT, DNS, NTP, and ordinary internet access;
  - every DHCP/DHCPv6 reservation and RA mode;
  - routing to/from `thebeyond` and all BT8-owned VLANs;
  - VLAN 51 restricted egress and other narrow workload policies;
  - allowed and denied inter-zone flows;
  - router-local SSH/LuCI/DNS/DHCP input policy;
  - Batman/VLAN behavior under representative load;
  - reboot and loss/recovery of the bridge;
  - deployment health checks and rollback procedure.
- [ ] **[Operator]** Test the management lockdown as a reversible runtime
      firewall change from the real approved operator source, then revert it.
- [ ] **[Operator] Gate 7** Schedule a physical cutover. Power down or disconnect
      the old gateway without altering it, install the candidate, and run the
      complete gateway acceptance checklist.
- [ ] **[Operator]** If any critical check fails, recable the old `bt8gw`; do not
      debug an unreachable gateway through the failed path.
- [ ] **[Operator]** Soak the replacement gateway while the original remains a
      recoverable unit.
- [ ] **[LLM analysis]** Compare production observations with the expected flow
      matrix and generated configuration; classify any deviation before making
      changes.
- [ ] **[Operator + LLM] Gate 8** Accept the gateway or roll back.

## Phase 8: Configure the remaining BT8

- [ ] **[Operator + LLM]** Reconfirm the third device's intended role based on
      the now-stable topology.
- [ ] **[Implementation]** Add its device declaration and tests using the shared
      BT8 hardware and role modules; avoid cloning a configuration with duplicate
      addresses or identities.
- [ ] **[Operator]** Back up/install ubootmod, deploy, and validate it using the
      same isolated procedure as Phase 6.
- [ ] **[Operator]** If it joins the live mesh, introduce it only after verifying
      its unique identity, allowed VLANs, Batman behavior, and effect on path
      selection. Otherwise document and periodically test the cold/warm-spare
      recovery procedure.

## Phase 9: Migrate the GS1900-10HP independently

This phase can occur before or after the BT8 rotation only if it has its own
maintenance window. It must not overlap a BT8 cutover.

### 9.1 Make-before-break management transition

- [ ] **[Operator]** Connect serial console or establish a direct physical
      recovery access port that is not the trunk being modified.
- [ ] **[Operator]** Confirm the upstream trunk carries the target management
      VLAN end-to-end before changing the switch CPU-port membership.
- [ ] **[Operator]** Add the target management VLAN and a temporary second
      management address while retaining the existing VLAN 20 path.
- [ ] **[Operator]** From an approved workstation, verify ping, SSH, and LuCI on
      the new path. Verify ordinary switching and all existing VLANs.
- [ ] **[Operator]** Apply the intended service-binding/firewall restriction
      with an automatic rollback timer or console session. Confirm approved
      access and denied access from VLAN 20 and other unapproved sources.
- [ ] **[Operator]** Remove the VLAN 20 address only after the new path and
      recovery path are independently proven. Removing an address must not be
      conflated with removing VLAN 20 data-plane switching if VLAN 20 remains a
      required user VLAN.
- [ ] **[LLM analysis]** Compare resulting runtime UCI and reachability with the
      approved switch model and explain any adjustment needed before imaging.

### 9.2 PoE validation

- [ ] **[Operator]** Confirm the exact supported PoE control API and inspect
      voltage/current/power reporting with no valuable powered device attached.
- [ ] **[Operator]** Test the intended port using a harmless standards-compliant
      powered device and verify negotiation, budget, enable/disable, reboot
      behavior, overload handling, and reporting.
- [ ] **[Operator]** Do not make a future JetKVM the first PoE test load. Update
      the policy after the purchased model's standard and power requirements are
      known.

### 9.3 Declarative image cutover

- [ ] **[Implementation]** Reconcile any proven runtime adjustments into the
      generated switch configuration and rerun switch/OpenWrt tests.
- [ ] **[Operator + LLM] Gate 9** Review the exact image, sysupgrade support,
      recovery method, port map, management path, and PoE behavior.
- [ ] **[Operator]** Deploy the clean switch image only with serial/direct
      recovery available. Validate management, every tagged/untagged port, STP
      behavior if applicable, end-to-end VLAN reachability, and PoE policy.
- [ ] **[Operator]** Restore the previous image/configuration immediately if
      management or required forwarding is not correct.
- [ ] **[Operator]** Soak the switch and inspect PoE/thermal/error counters before
      declaring it managed.

## Phase 10: Closeout and ongoing management

- [ ] **[LLM analysis]** Produce final as-built-versus-declared reports for all
      devices. There must be no unexplained meaningful UCI drift.
- [ ] **[Implementation]** Promote current operator procedures from this WIP plan
      into `docs/`: per-hardware recovery, build/deploy, secret rotation,
      acceptance checks, and safe rollout order.
- [ ] **[Implementation]** Update/supersede B.1-B.3 and D.2 in
      `dual-gateway-followups-plan.md` to point to completed work rather than
      retaining duplicate stale instructions.
- [ ] **[Operator]** Store final factory backups, last-known-good images,
      artifact digests, host-key records, and cabling diagrams in the operator
      backup system.
- [ ] **[Operator]** Schedule periodic restoration tests and staged OpenWrt
      upgrades: bridge/spare first, gateway second, switch separately.
- [ ] **[Operator + LLM] Gate 10** Mark this plan done only after all active
      devices are declarative, recovery is documented and tested, and the live
      network has completed its agreed soak periods.

## Deferred follow-ups

These require new evidence and are not acceptance criteria for the import:

- Evaluate `usteer` for client AP roaming independently of the 802.11s/Batman
  backhaul.
- Collect channel utilization, noise, retry, DFS, and Batman quality telemetry.
- If fixed-channel operation is materially inadequate, write a separate design
  for a narrow batman-compatible channel coordinator. It must not enable HWMP
  forwarding or take ownership of bridges, DHCP, firewall, or VLAN topology.
- Revisit DFS channels only with an emergency rendezvous/fallback design and
  verified BT8 driver behavior.
- Consider CI-driven staged deployment only after manual role-specific health
  checks and rollback have been proven on the actual hardware.

## Immediate next action

Complete Phase 0, then provide the scrubbed Phase 1 text captures in the ignored
local directory. The first LLM deliverable is the Phase 2 as-built inventory and
disposition table; no device module or live change should precede that review.
