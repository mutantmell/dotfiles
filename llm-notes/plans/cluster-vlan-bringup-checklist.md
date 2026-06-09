# Cluster VLAN 51 Bring-up — Status Checklist

**Status: IN PROGRESS — Phase A done (flake); B flake-half done; C
operator-confirmed applied (egress confined to transit/zeiss/creil, 2026-06-09);
D flake-half done (D.1–D.2 Multus chart + D.3 reworked to per-slot baked NADs;
D.4–D.6 launcher rework → multus-only + slot model + direct-SSH access), pending
cluster apply (the `lab → cluster` ingress the direct-SSH path needs is **already**
permitted by bt8gw's existing broad lab/wg-vpn→cluster forwarding); D.7/E/F
remaining.** Drafted 2026-06-08; Phase A landed 2026-06-08.
Phase B flake half (`uplink.51` + `br51`) landed 2026-06-09; bt8gw L3 termination
reported live 2026-06-09 (`ping 10.97.51.1` answers). Phase C fw4 zone + egress
allowlist **operator-confirmed enforcing 2026-06-09** — VLAN 51 reaches only
transit (WAN), zeiss, and creil; the broad-accept risk did **not** materialize.
DNS (C.4) is **also confirmed** — a `Allow-DNS-DHCP-cluster` rule admits VLAN 51
to the bt8gw resolver. Residual: exact as-built UCI delta + enforcing mechanism
(§2 vs §2b) not captured verbatim here.

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

| Value                     | Setting                                                                    |
| ------------------------- | -------------------------------------------------------------------------- |
| VLAN 51 IPv4              | `10.97.51.0/24`, gateway `10.97.51.1` (bt8gw)                              |
| VLAN 51 IPv6 (ULA)        | `fdc6:55f2:0a5e:1033::/64`, gateway `…1033::1`                             |
| erebonia mgmt (unchanged) | `10.97.11.31` (VLAN 11) — keeps apiserver, SSH, NFS                        |
| dev-VM slots              | `dev-1`..`dev-16` = `10.97.51.10`..`.25` (static names, dynamic occupancy) |
| dev-VM egress targets     | `creil` `10.97.50.53` :22+:443 · `zeiss` `10.97.50.31` :443 · DNS · WAN    |
| mobile peer (rider)       | `wg-vpn` `mobile` = `10.100.10.21` → :22 + UDP 60000–61000                 |

---

## Phase A — Registry & zone declaration [flake] (maps to plan Phase 1)

_No behavior change; pure registry + naming. Mergeable on its own._

- [x] **A.1** Add the `cluster` zone to `lib/common/data/network.nix`
  - [x] `cluster = { vlanId = 51; gateway = "bt8gw"; hosts = { … }; }` — derives
        `10.97.51.0/24` + `fdc6:55f2:0a5e:1033::/64` automatically (eval-confirmed:
        gateway `.1`, subnets, and ULA segment `1033` all match the plan)
  - [x] Register **16 named dev-machine slots** `dev-1`..`dev-16` →
        `10.97.51.10`..`.25` (generated via `lib.genList`). **Static names,
        dynamic occupancy:** the Phase D launcher assigns a free slot's IP/MAC to
        each ephemeral dev VM, so adding/removing machines needs no registry edit
        (avoids the single-`dev-machine` pin, which wrongly assumed exactly one).
        Slots flow through the existing authoritative DNS path; cap is 16
        concurrent (band headroom `.26–.31`; `.32+` stays free for the deferred
        dynamic pool / LB / erebonia-egress). If we outgrow static slots → kresd
        programmatic-DNS (plan's "registry & DNS" eventual note).
  - [x] Confirm `dupHostnames`/`dupVlanIds`/`hostRangeCheck`/`dupHostIdCheck` still
        pass — `network-registry` check green; `dev-1`..`dev-16` are fresh names
        and IDs `.10–.25` are unique within the zone
- [-] **A.2** ~~Add a `cluster` naming stub to `hosts/thebeyond/router.nix`~~ —
  **dropped: not needed.** The checklist (and the plan's "Where VLAN 51
  terminates") said to mirror the `app` stub "so cross-zone references resolve."
  Verified that is **false** for `cluster`: on thebeyond a zone is load-bearing
  only if (a) an interface binds to it (`network.zone`, enum-typed), (b) another
  zone names it in `accessTo` (enum-typed), or (c) another zone names it as a
  `forwardRules` key (validated by a router6 assertion). **Nothing on thebeyond
  does any of these for `cluster`** — and it can't: `cluster` is bt8gw-owned, so
  thebeyond only ever reaches it _across the gateway split via `transit`_ (which
  is why the existing `transit` rules gate the "transit→app side" by `daddr`
  rather than naming an `app` zone). An interface-less zone is also filtered out
  of `activeZones`, so it emits zero rules. **Proof:** removed the stub and
  `nix eval .#nixosConfigurations.thebeyond.config.networking.nftables.ruleset`
  renders clean with **0** occurrences of `cluster`. (The pre-existing `app`
  stub appears to be dead weight for the same reason — left untouched here, out
  of scope.)
- [x] **A.3** DNS for every slot flows automatically: registry host →
      `mkUnboundLocalData` → phantasma. Verified `dev-1`..`dev-16` (`.internal` +
      FQDN, A + AAAA, e.g. `dev-16` → `…1033::19`) appear in generated local-data
      and `dnsHosts`; no manual DNS edit. A launched VM gets `dev-N.internal` for
      the life of its occupancy of slot N.
- [x] **A.4** `nix fmt` (clean) + `./scripts/run-checks.sh network-registry
network-helpers router6-zone-system router6-firewall-zones router6-assertions
router6-firewall` all green.

## Phase B — L2 plumbing [L2 + flake] (maps to plan Phase 2, L2 part)

_Get tag 51 from bt8gw to a bridge on erebonia. The bridge is **host-IP-less**._

- [~] **B.1** **[bt8gw manual]** Add VLAN 51 to bt8gw's wired trunk: `br0`
  `bridge-vlan` filtering carries tag 51, plus the `br-v51` L3-terminating
  bridge (`bat0.51` + `br0.51`). UCI staged in
  `temp/BT8-gw-cluster-vlan51-additions.uci` §1. **L3 termination reported
  live 2026-06-09** (`ping 10.97.51.1` answers); reconcile the staged §1
  against `uci show network` to confirm the exact as-built shape.
- [~] **B.2** **[L2]** Confirm tag 51 traverses the mesh path bt8gw → erebonia
  (whatever segment erebonia's `uplink` trunk rides). The gateway answering
  from a remote VLAN-51 host is partial evidence; still want a `tcpdump -ni
    uplink.51` on erebonia to confirm tagged frames land on the host trunk.
- [x] **B.3** **[flake]** In `hosts/erebonia/microvm/default.nix` add
      `uplink.51` (netdev vlan id 51) to the `uplink` trunk's `vlan` list, and a
      **host-IP-less** bridge `br51` enslaving `uplink.51` (no `Address`, no
      `DHCP`, no `LinkLocalAddressing` — mirror `br21`, **not** `br11`). **Done
      2026-06-09** — `20-uplink.51` netdev + `20-vm51-bridge` enslave + host-IP-less
      `20-br51`; erebonia config evals clean.
- [x] **B.4** **[flake]** Ensure erebonia's host firewall does **not** trust
      `uplink.51`/`br51` (leave them out of `networking.firewall.trustedInterfaces`,
      which stays `["cni0" "flannel.1"]`). The host holds no VLAN-51 IP in this
      slice, so there is nothing to expose — just don't add one. **Confirmed
      2026-06-09** — `trustedInterfaces` unchanged (`k3s/default.nix:166`); `br51`
      is host-IP-less so the default-drop input policy leaves zero VLAN-51 surface.

## Phase C — bt8gw cluster zone + egress [bt8gw manual] (maps to plan Phase 2, fw4 part)

_All UCI/LuCI on bt8gw — staged in `temp/BT8-gw-cluster-vlan51-additions.uci`
(§1 = C.1, §2 = C.2–C.6, §2b = the strict-egress fallback) + the "Cluster VLAN 51
additions" section of `bt8-gateway-as-built.md` (the Phase 5.A pattern)._

- [x] **C.1** Terminate VLAN 51 on bt8gw: interface with `10.97.51.1/24` +
  `…1033::1/64`. DHCP optional (deferred — see plan IPAM note; the dev slots
  are static, so DHCP is **not** required for this slice). **Live 2026-06-09**
  (`ping 10.97.51.1`); staged UCI §1.
- [x] **C.2** Create the `cluster` fw4 zone (input/forward/output default
      `REJECT`/`DROP`; `icmpEcho` off as desired). **Operator-confirmed applied
      2026-06-09.** Staged UCI §2.
- [x] **C.3** `cluster → app` allow: `creil` :22 (git SSH push) **and** :443
      (HTTPS clone + container-registry pull), `zeiss` :443 (Attic). **THE SHARP
      ITEM — RESOLVED:** operator confirms VLAN 51 reaches **only** zeiss + creil
      on app (not all of app), so the Phase-5.A broad-accept risk did **not**
      materialize — egress is tight. (Which mechanism enforced — plain §2 vs the
      §2b nft include — not captured verbatim here; confirm on next device touch
      and record per C.7.)
- [x] **C.4** `cluster → <DNS resolver>` allow :53 (the VLAN-51 resolver path —
      a multus-only VM has **no** in-cluster DNS). **Operator-confirmed
      2026-06-09** — a `Allow-DNS-DHCP-cluster` rule admits VLAN 51 to the bt8gw
      resolver (bt8gw dnsmasq input :53, recurses upstream to thebeyond kresd →
      phantasma), so the multus-only VM can resolve `dev-N.internal` and the egress
      hostnames. (Rule name `Allow-DNS-DHCP-cluster` differs from the staged §2
      `Allow-cluster-DNS`; reconcile when capturing the as-built delta.)
- [x] **C.5** `cluster → WAN` allow as needed for the dev image's external pulls
      (or scope tighter if the allowlist is known). **Operator-confirmed
      2026-06-09** (transit reachable). Staged UCI §2 → `cluster → transit` (WAN
      via thebeyond NAT; thebeyond's transit-side fw gates onward).
- [x] **C.6** `cluster → *` (management, lab, trusted, other) **deny** —
      default-deny is the point; only C.3–C.5 punch through. **Operator-confirmed
      2026-06-09** — egress limited to transit/zeiss/creil; everything else denied
      by the zone forward `REJECT` default.
- [~] **C.7** `fw4 reload` done (rules live). **Residual:** record the
      **as-built** UCI delta + which egress mechanism (plain §2 vs §2b) ended up
      enforcing, in the as-built note — not yet captured verbatim here.

## Phase D — KubeVirt attachment (multus-only) [cluster + flake] (maps to plan Phase 4)

_Move the dev VM off the flannel pod network onto VLAN 51 directly._

- [~] **D.1** **[cluster]** Install **Multus** — **flake-authored**
      (`hosts/erebonia/k3s/multus.nix`) via the **rke2-multus** Helm chart
      (4.2.411) through `services.k3s.autoDeployCharts` (FOD-pinned, same posture
      as `cert-manager.nix`/`flux.nix`). Chose the Rancher chart because the
      official k3s docs prescribe it for Multus-on-k3s — its DaemonSet writes the
      multus binary + plugins into k3s' writable `/var/lib/rancher/k3s/data/cni/`,
      sidestepping the immutable `data/<hash>/bin` problem. Additive; flannel stays
      primary. **Pending cluster apply + runtime verify** (DaemonSet Running).
- [~] **D.2** **[cluster]** bridge + static CNI plugins — **satisfied by the
      chart**: rke2-multus bundles the reference plugin set (bridge, static,
      host-local, macvlan, …) into the binDir, so no separate
      `containernetworking-plugins` drop. **Verify post-apply**:
      `ls /var/lib/rancher/k3s/data/cni/` shows `bridge` + `static`.
- [~] **D.3** **[cluster]** `NetworkAttachmentDefinition`s — **flake-authored**
      (`multus.nix`, `services.k3s.manifests`, `.content` so they re-apply until the
      NAD CRD exists). **Reworked to 16 per-slot NADs** `cluster-vlan51-dev-1`..`-16`
      (was a single `cluster-vlan51` relying on per-VM `ips`-annotation injection —
      **dropped because KubeVirt owns the `k8s.v1.cni.cncf.io/networks` annotation
      and ignores a VM-spec `ips` field (kubevirt/kubevirt#4564), and the base image
      is DHCP-only with no cloud-init**). Each NAD bridges `br51` (B.3,
      host-IP-less) and **bakes that slot's registry IP** into `static` IPAM
      (`10.97.51.<10+N-1>/24` + the `…1033::` v6) with v4/v6 default routes at the
      bt8gw gateway; KubeVirt's bridge-binding DHCP then leases the baked IP to the
      guest. Lands in a flake-declared `dev-machines` namespace. Eval-verified (all
      16 NAD JSONs render the correct slot IPs). **Pending cluster apply.**
- [x] **D.4** **[flake]** Switched the dev-VM manifest in
      `home/modules/dev-machine.nix` from `masquerade` to **multus + bridge,
      multus-only** (dropped the default pod network; single `bridge` interface on
      the slot NAD). The **slot** model drives identity: the launcher picks a free
      slot `dev-N`, patches the VM's `networks[0].multus.networkName` to that slot's
      NAD `cluster-vlan51-dev-N` (carrying its IP via static IPAM) and a
      deterministic per-slot `macAddress` (the one field KubeVirt honors). No per-VM
      registry edit — names are static (A.1), occupancy assigned at launch.
- [x] **D.5** **[flake]** Free-slot bookkeeping is **cluster-sourced** (not local
      state): the launcher labels each VM `dev-machine-slot=dev-N` and reads
      occupancy back from those labels across all VMs, so it reuses a name's slot on
      re-`up` and refuses when all 16 are taken (`assign_free_slot`). The slot IP is
      its registry address → authoritative `dev-N.internal` DNS (A.3).
- [x] **D.6** **[flake]** Reworked the operator access path: the
      `kubectl port-forward`/masquerade hack is **removed** (dead under multus-only —
      no pod network to forward through), replaced by **direct SSH to
      `dev-N.internal`** (devpod provider points straight at the slot host;
      `ssh`/`refresh`/`rescue`/extract all use it). `console` (virtctl) kept as the
      fallback. **No new bt8gw rule needed**: lab→cluster (and wg-vpn→cluster) is
      **already broadly permitted** by existing bt8gw forwarding, so the direct-SSH
      path works today. A scoped §2c `lab → cluster` accept (edith `10.97.21.42` →
      dev band `.10-.25` tcp 22) is staged only as optional tightening if that broad
      forwarding is later narrowed.
- [ ] **D.7** Acceptance: from the VM, `git clone`/push to creil (`:443`/`:22`),
      pull the dev image, reach Attic — **and** confirm it **cannot** reach a
      management host (e.g. `nc -vz` to a VLAN-11 service times out). This is Phase 5
      proven.

## Phase E — `wg-vpn → cluster` rider [bt8gw manual] (maps to plan Phase 4 rider)

_Direct mobile reach — unblocks kubevirt Phase 6 pieces 5–6._

- [ ] **E.1** bt8gw fw4 `transit → cluster` accept, `saddr = 10.100.10.21` (the
      `mobile` wg peer), `daddr` = the dev-slot band `10.97.51.10–.25`, **TCP :22**
      (mosh/ssh bootstrap) **+ UDP 60000–61000** (mosh data). Narrow to the band,
      not the whole zone. (One rule covers all 16 slots — they share the egress
      and ingress policy, so no per-slot rules.)
- [ ] **E.2** Confirm no router6 edit is needed on thebeyond: `wg-vpn.accessTo`
      already includes `transit`, so thebeyond already forwards `wg-vpn →
10.97.0.0/16` (gated by bt8gw fw4 — the rule above is the only gate).
- [ ] **E.3** Acceptance: from the mobile (over `wg-vpn`), `mosh
dev@dev-N.internal` (the slot the target VM occupies) connects and attaches the
      in-container zellij. (The
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
- [-] **LB-IPAM (MetalLB)** for routable _service_ VIPs (plan Phase 5 / kubevirt
  Phase 6's service tier). Not needed to reach the dev VM.
- [-] **NetworkPolicy default-deny.** Inert for a multus-only VM (no flannel NIC
  for kube-router to govern); the router (bt8gw fw4) is the sole enforcer. Apply
  later only if pod-network workloads share the namespace.
- [-] **Dynamic-pool IPAM** (Whereabouts vs bt8gw DHCP). Named hosts are
  static+registry; resolve the ephemeral-tier IPAM only when an unpinned pool is
  actually wanted (plan IPAM open question).
- [-] **Removing WAN from VLAN 11.** Independent trigger; pairs with the flannel
  redirect above.
