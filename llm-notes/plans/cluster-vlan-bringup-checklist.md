# Cluster VLAN 51 Bring-up — Status Checklist

**Status: NOT STARTED.** Drafted 2026-06-08.

Companion status doc for
[`workload-network-isolation-plan.md`](workload-network-isolation-plan.md). This
checklist is the **critical-path slice** of that plan — the minimum needed to put
the locked-down dev-machine VM on VLAN 51 and reach it directly from mobile. It
deliberately does **not** implement the whole isolation plan (see "Explicitly
deferred" below).

**What it unblocks:**

- `ai-dev-machine-kubevirt-plan.md` **Phase 5** (devcontainer network lockdown) —
  the VM becomes a routable host in the low-trust `cluster` zone, isolated from
  erebonia's management VLAN by construction and confined by bt8gw fw4.
- `ai-dev-machine-kubevirt-plan.md` **Phase 6 pieces 5–6** (direct mobile access)
  — routable VM + DNS + the `wg-vpn → cluster` hole.

**Legend:** `[ ]` not started · `[~]` in progress · `[x]` done · `[-]` skipped/N/A

**Enforcement reality (read first):** VLAN 51 is **bt8gw-owned/terminated**, and
bt8gw is **OpenWrt fw4, hand-managed via UCI/LuCI — not built from this flake**
(see the plan's "Where VLAN 51 terminates"). So this work is **mixed**: flake
edits on erebonia/registry **plus** manual UCI on bt8gw **plus** L2 plumbing
across bt8gw + mesh + erebonia. Per-phase the surface is marked **[flake]** /
**[bt8gw manual]** / **[L2]** / **[cluster]** (k8s objects).

| Value | Setting |
| --- | --- |
| VLAN 51 IPv4 | `10.97.51.0/24`, gateway `10.97.51.1` (bt8gw) |
| VLAN 51 IPv6 (ULA) | `fdc6:55f2:0a5e:1033::/64`, gateway `…1033::1` |
| erebonia mgmt (unchanged) | `10.97.11.31` (VLAN 11) — keeps apiserver, SSH, NFS |
| dev-VM egress targets | `creil` `10.97.50.53` :22+:443 · `zeiss` `10.97.50.31` :443 · DNS · WAN |
| mobile peer (rider) | `wg-vpn` `mobile` = `10.100.10.21` → :22 + UDP 60000–61000 |

---

## Phase A — Registry & zone declaration [flake] (maps to plan Phase 1)

*No behavior change; pure registry + naming. Mergeable on its own.*

- [ ] **A.1** Add the `cluster` zone to `lib/common/data/network.nix`
  - [ ] `cluster = { vlanId = 51; gateway = "bt8gw"; hosts = { … }; }` — derives
        `10.97.51.0/24` + `fdc6:55f2:0a5e:1033::/64` automatically
  - [ ] Reserve a **pinned dev-VM host-ID band** (e.g. `10–31`) and register the
        first named machine (e.g. `dev-machine = 10`). Bands above it stay free
        for the (deferred) dynamic pool / LB / erebonia-egress
  - [ ] Confirm `dupHostnames`/`dupVlanIds`/`hostRangeCheck` still pass (eval) —
        do **not** name any cluster host with a name already used in another zone
        (e.g. `erebonia`)
- [ ] **A.2** Add the `cluster` **naming stub** to `hosts/thebeyond/router.nix`
  `router6.zones` (mirror the `app` stub: `icmpEcho = "disable"; accessTo = [];
  inputRules = [];`) so cross-zone references resolve. thebeyond does **not**
  bind an interface to it.
- [ ] **A.3** DNS for the pinned dev VM flows automatically: registry host →
  `mkUnboundLocalData` → phantasma. Verify `dev-machine.internal` appears in
  phantasma's generated local-data (no manual DNS edit needed).
- [ ] **A.4** `nix fmt` + `./scripts/run-checks.sh network-registry network-helpers`
  (and any router6 zone-system checks) green.

## Phase B — L2 plumbing [L2 + flake] (maps to plan Phase 2, L2 part)

*Get tag 51 from bt8gw to a bridge on erebonia. The bridge is **host-IP-less**.*

- [ ] **B.1** **[bt8gw manual]** Add VLAN 51 to bt8gw's wired trunk: `br0`
  `bridge-vlan` filtering carries tag 51, plus an L2-passthrough `br-v51` (same
  pattern as the VLAN-11/20/21 deviation in the dual-gateway checklist). See
  `guides/bt8-gateway-luci-runbook.md`.
- [ ] **B.2** **[L2]** Confirm tag 51 traverses the mesh path bt8gw → erebonia
  (whatever segment erebonia's `uplink` trunk rides). Sanity: `tcpdump` a tagged
  frame arrives on erebonia.
- [ ] **B.3** **[flake]** In `hosts/erebonia/microvm/default.nix` add
  `uplink.51` (netdev vlan id 51) to the `uplink` trunk's `vlan` list, and a
  **host-IP-less** bridge `br51` enslaving `uplink.51` (no `Address`, no
  `DHCP`, no `LinkLocalAddressing` — mirror `br21`, **not** `br11`).
- [ ] **B.4** **[flake]** Ensure erebonia's host firewall does **not** trust
  `uplink.51`/`br51` (leave them out of `networking.firewall.trustedInterfaces`,
  which stays `["cni0" "flannel.1"]`). The host holds no VLAN-51 IP in this
  slice, so there is nothing to expose — just don't add one.

## Phase C — bt8gw cluster zone + egress [bt8gw manual] (maps to plan Phase 2, fw4 part)

*All UCI/LuCI on bt8gw — capture as a `temp/*.uci` + as-built note like Phase 5.A.*

- [ ] **C.1** Terminate VLAN 51 on bt8gw: interface with `10.97.51.1/24` +
  `…1033::1/64`. DHCP optional (deferred — see plan IPAM note; the pinned dev VM
  is static, so DHCP is **not** required for this slice).
- [ ] **C.2** Create the `cluster` fw4 zone (input/forward/output default
  `REJECT`/`DROP`; `icmpEcho` off as desired).
- [ ] **C.3** `cluster → app` allow: `creil` :22 (git SSH push) **and** :443
  (HTTPS clone + container-registry pull), `zeiss` :443 (Attic). Scope `daddr` to
  those hosts.
- [ ] **C.4** `cluster → <DNS resolver>` allow :53 (the VLAN-51 resolver path —
  a multus-only VM has **no** in-cluster DNS).
- [ ] **C.5** `cluster → WAN` allow as needed for the dev image's external pulls
  (or scope tighter if the allowlist is known).
- [ ] **C.6** `cluster → *` (management, lab, trusted, other) **deny** —
  default-deny is the point; only C.3–C.5 punch through.
- [ ] **C.7** `fw4 reload`; record the UCI delta + rationale in an as-built note.

## Phase D — KubeVirt attachment (multus-only) [cluster + flake] (maps to plan Phase 4)

*Move the dev VM off the flannel pod network onto VLAN 51 directly.*

- [ ] **D.1** **[cluster]** Install **Multus** (operator-manifest or HelmChart,
  same auto-apply pattern as `kubevirt.nix`/`cert-manager.nix` in
  `hosts/erebonia/k3s/`). Multus is additive; flannel stays the primary CNI for
  everything else.
- [ ] **D.2** **[cluster]** Confirm the **bridge** + **static/cluster** IPAM CNI
  plugin binaries are present in k3s' CNI bin dir (k3s bundles a limited set —
  add `containernetworking-plugins` if `bridge` is missing).
- [ ] **D.3** **[cluster]** `NetworkAttachmentDefinition` for VLAN 51: bridge =
  `br51` (the host-IP-less bridge from B.3), static IPAM (or pinned per-VM via
  the manifest). Author it the repo way (Nix attrset → `services.k3s.manifests`
  or the dev-machine module, per where it best lives).
- [ ] **D.4** **[flake]** Switch the dev-VM manifest in
  `home/modules/dev-machine.nix` from `masquerade` binding to **multus + bridge,
  multus-only** (drop the default pod network from `networks`/`interfaces`; add
  the NAD network + a `bridge` interface; set a **stable `macAddress`** so the
  pinned IP/DNS is deterministic).
- [ ] **D.5** **[flake]** Pin the VM's VLAN-51 IP to its registry address
  (`10.97.51.<id>`) via NAD static IPAM or cloud-init; verify it resolves as
  `dev-machine.internal`.
- [ ] **D.6** **[flake]** Rework the operator access path now that the VM is
  routable: the `kubectl port-forward`/masquerade SSH hack
  (`home/modules/dev-machine.nix`) can become **direct SSH to
  `dev-machine.internal`** from edith (lab zone). (Keep the `console` fallback.)
- [ ] **D.7** Acceptance: from the VM, `git clone`/push to creil (`:443`/`:22`),
  pull the dev image, reach Attic — **and** confirm it **cannot** reach a
  management host (e.g. `nc -vz` to a VLAN-11 service times out). This is Phase 5
  proven.

## Phase E — `wg-vpn → cluster` rider [bt8gw manual] (maps to plan Phase 4 rider)

*Direct mobile reach — unblocks kubevirt Phase 6 pieces 5–6.*

- [ ] **E.1** bt8gw fw4 `transit → cluster` accept, `saddr = 10.100.10.21` (the
  `mobile` wg peer), `daddr` = the dev-VM band, **TCP :22** (mosh/ssh bootstrap)
  **+ UDP 60000–61000** (mosh data). Narrow to the band, not the whole zone.
- [ ] **E.2** Confirm no router6 edit is needed on thebeyond: `wg-vpn.accessTo`
  already includes `transit`, so thebeyond already forwards `wg-vpn →
  10.97.0.0/16` (gated by bt8gw fw4 — the rule above is the only gate).
- [ ] **E.3** Acceptance: from the mobile (over `wg-vpn`), `mosh
  dev@dev-machine.internal` connects and attaches the in-container zellij. (The
  mosh/zellij/attach-helper image pieces are kubevirt Phase 6 pieces 1–4 — land
  those in parallel; they work over the edith-jump interim regardless.)

## Phase F — verification / acceptance

- [ ] **F.1** **Security:** dev VM is on VLAN 51, has no flannel NIC, cannot
  reach management/lab/trusted except C.3–C.5; erebonia's mgmt identity untouched
  on VLAN 11.
- [ ] **F.2** **Mobile:** direct `mosh` from the `mobile` peer works without the
  edith hop.
- [ ] **F.3** **Regression:** other k3s workloads (plain flannel pods) and the
  existing microVMs/Incus guests on erebonia are unaffected (flannel still
  primary, VLAN 11 mgmt intact).
- [ ] **F.4** Move this checklist + the isolation plan to `wip/` once Phase A (or
  the first phase) merges; tick items as they land.

---

## Explicitly deferred (out of scope for this slice)

These are real parts of the isolation plan but **not** on the dev-machine /
mobile critical path — do them later, independently:

- [-] **erebonia host-side flannel-egress redirect** (the `ip rule` +
  source-based policy routing + masquerade onto a VLAN-51 host egress address).
  The dev VM is multus-only and bypasses flannel, so it needs none of this. This
  is for **general flannel pods** and is required only when **WAN is removed from
  VLAN 11** (plan Phase 2's host-side step / the WAN-removal trigger).
- [-] **LB-IPAM (MetalLB)** for routable *service* VIPs (plan Phase 5 / kubevirt
  Phase 6's service tier). Not needed to reach the dev VM.
- [-] **NetworkPolicy default-deny.** Inert for a multus-only VM (no flannel NIC
  for kube-router to govern); the router (bt8gw fw4) is the sole enforcer. Apply
  later only if pod-network workloads share the namespace.
- [-] **Dynamic-pool IPAM** (Whereabouts vs bt8gw DHCP). Named hosts are
  static+registry; resolve the ephemeral-tier IPAM only when an unpinned pool is
  actually wanted (plan IPAM open question).
- [-] **Removing WAN from VLAN 11.** Independent trigger; pairs with the flannel
  redirect above.
