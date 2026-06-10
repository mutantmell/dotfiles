# Cluster VLAN 51 Bring-up — Status Checklist

**Status: ★ BOTH GOALS PROVEN 2026-06-10 — GOAL A (kubevirt P5) + GOAL B
(kubevirt P6 pieces 5–6). ★** Only Phase F housekeeping remains (F.3 regression
sweep, C.7 as-built capture) — none of it changes the live system. **F.4 doc
moves are done (2026-06-10):** this checklist + the isolation plan are now in
`wip/`, and the completed kubevirt plan moved to `done/`.
Phase A done (flake); B done (L2 confirmed by end-to-end DHCP+egress); C
operator-confirmed applied (egress confined to transit/zeiss/creil, 2026-06-09);
D applied + **runtime-verified on the cluster 2026-06-10** — the dev VM came up
multus-only via macvtap (D.1–D.6, the **macvtap cutover**: Multus chart +
macvtap-cni, ONE macvtap NAD, multus-only slot launcher, direct-SSH access),
DHCP'd slot `dev-1`'s reservation (`10.97.51.10`, MAC `02:51:51:00:00:0a`) plus
native VLAN-51 SLAAC IPv6 off the bt8gw RA. **D.7 acceptance passed**: from the
VM, creil `:22`/`:443` + zeiss `:443` + WAN reachable and DNS resolves
(`dev-1.internal`, `creil.internal`), while erebonia mgmt (`10.97.11.31`) `:22`,
`:6443` (apiserver), `:2049` (NFS) all **time out** — the dev VM cannot reach the
management VLAN. F.1 (security) confirmed.
**Goal B (mobile) — PROVEN 2026-06-10**: from the mobile device over `wg-vpn`,
`mosh dev@dev-1.internal` connects directly (no edith hop) and the session
**persists across network changes** where plain SSH dropped (E.3 + F.2). As
predicted, **no new bt8gw fw4 rule was needed** — the existing broad
`wg-vpn → cluster` forwarding already admitted it, so the scoped E.1
`transit → cluster` rule is now purely **optional tightening** (E.2 also
confirmed: no thebeyond router6 edit). **Only Phase F housekeeping remains:** F.3
regression (erebonia-side — flannel/Incus/mgmt intact) + C.7
as-built capture. Drafted 2026-06-08; Phase A landed 2026-06-08.
Phase B flake half landed 2026-06-09 (originally `uplink.51` + a host-IP-less
`br51`); bt8gw L3 termination reported live 2026-06-09 (`ping 10.97.51.1`
answers). **The br51 bridge was then RETIRED by the macvtap cutover
(2026-06-10)** — `br_netfilter` silently dropped routed-in (`lab → dev-N`)
traffic to a host-bridge guest under k3s' `bridge-nf-call=1`; the dev VMs now
attach via KubeVirt **macvtap** on a standalone `uplink.51` carrier (the house
pattern, matching VLAN 50/100). See
[`../wip/dev-machine-vlan51-macvtap-cutover.md`](../wip/dev-machine-vlan51-macvtap-cutover.md).
Phase C fw4 zone + egress allowlist **operator-confirmed enforcing 2026-06-09** —
VLAN 51 reaches only transit (WAN), zeiss, and creil; the broad-accept risk did
**not** materialize. DNS (C.4) is **also confirmed** — a `Allow-DNS-DHCP-cluster`
rule admits VLAN 51 to the bt8gw resolver. Residual: exact as-built UCI delta +
enforcing mechanism (§2 vs §2b) not captured verbatim here.

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
| dev-VM slots              | `dev-1`..`dev-16` = `10.97.51.10`..`.25` (static names, dynamic occupancy; IP via **bt8gw per-slot DHCP reservation** keyed on the slot MAC `02:51:51:00:00:<hex(9+N)>` — stable, ✅ in place) |
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
- [x] **B.2** **[L2]** Tag 51 traverses the mesh path bt8gw → erebonia.
  **Confirmed end-to-end 2026-06-10**: the dev VM (a macvtap child of `uplink.51`)
  DHCP'd its slot IP from bt8gw and has working bidirectional egress, which proves
  tagged frames land on the host trunk and cross the mesh in both directions — a
  stronger proof than the originally-planned `tcpdump -ni uplink.51`.
- [x] **B.3** **[flake]** In `hosts/erebonia/microvm/default.nix` add
      `uplink.51` (netdev vlan id 51) to the `uplink` trunk's `vlan` list.
      Originally also added a **host-IP-less** bridge `br51` enslaving `uplink.51`
      (done 2026-06-09) — **but `br51` was RETIRED by the macvtap cutover
      (2026-06-10).** `uplink.51` is now a **standalone carrier-only** network
      (matching the existing `20-vm50-macvtap` / `20-vm100-macvtap` pattern); the
      macvtap-cni device plugin parents its macvtap children directly on it. A host
      bridge re-introduces the `br_netfilter` drop of routed-in VLAN-51 traffic
      under k3s' `bridge-nf-call=1`, which is exactly why it was removed. See the
      macvtap cutover note (Change D).
- [x] **B.4** **[flake]** Ensure erebonia's host firewall does **not** trust
      `uplink.51` (leave it out of `networking.firewall.trustedInterfaces`, which
      stays `["cni0" "flannel.1"]`). The host holds no VLAN-51 IP — there is
      nothing to expose. **Still true post-cutover**: macvtap gives the host **no**
      L3 presence on VLAN 51 (carrier only), so the default-drop input policy
      leaves zero VLAN-51 surface — and macvtap adds host↔guest isolation by
      construction (a stated goal the host-IP-less bridge was carrying).

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
- [~] **C.7** `fw4 reload` done (rules live). **Enforcement behaviourally
      confirmed 2026-06-10** from a VLAN-51 dev machine: creil `:443`/`:22` +
      zeiss `:443` answer, but the *other* app hosts oracion `10.97.50.52`
      `:443`/`:22` and saint-arkh `10.97.50.61` `:443` **time out** — so
      `cluster→app` is a tight allowlist, not a broad accept (the Phase-5.A risk
      did not materialize; extends D.7's mgmt-only test to other app hosts). DNS
      rule-name reconciled: live/authoritative name is `Allow-DNS-DHCP-cluster`
      (staged `Allow-cluster-DNS` superseded). **Residual DEFERRED — not a bt8gw
      shell touch.** Capturing the verbatim UCI delta + which mechanism (plain §2
      vs §2b nft include) enforces is folded into
      [`plans/dual-gateway-followups-plan.md`](../plans/dual-gateway-followups-plan.md)
      §B.1 (codify BT8-gateway in the flake): once the config is flake-managed and
      snapshot-tested, the enforcing rules are the in-repo source and the
      hand-capture dissolves. No interim manual snapshot — the as-built note has
      been a source of confusion. Behaviourally, C.7 is **proven**; only the
      doc-of-record migrates.

## Phase D — KubeVirt attachment (multus-only) [cluster + flake] (maps to plan Phase 4)

_Move the dev VM off the flannel pod network onto VLAN 51 directly._

- [x] **D.1** **[cluster]** Install **Multus** — **flake-authored**
      (`hosts/erebonia/k3s/multus.nix`) via the **rke2-multus** Helm chart
      (4.2.411) through `services.k3s.autoDeployCharts` (FOD-pinned, same posture
      as `cert-manager.nix`/`flux.nix`). Chose the Rancher chart because the
      official k3s docs prescribe it for Multus-on-k3s — its DaemonSet writes the
      multus binary + plugins into k3s' writable `/var/lib/rancher/k3s/data/cni/`,
      sidestepping the immutable `data/<hash>/bin` problem. Additive; flannel stays
      primary. **Applied + verified 2026-06-10** (the dev VM attached multus-only).
- [x] **D.2** **[cluster]** CNI plugins — Multus reference plugins **satisfied by
      the rke2-multus chart** (it bundles bridge, static, host-local, macvlan, … into
      the binDir). The macvtap path also needs **macvtap-cni** (CNI plugin + device
      plugin) — **flake-authored** (`multus.nix`): a pinned-image DaemonSet that
      installs the `macvtap` CNI binary and advertises `capacity = 16` allocatable
      macvtap devices on `uplink.51` as the extended resource
      `macvtap.network.kubevirt.io/vlan51`. **Applied + verified 2026-06-10** — the
      VM's macvtap NIC allocated successfully (a macvtap child of `uplink.51`), which
      requires the device-plugin resource to have advertised and the `macvtap` CNI
      binary to be present in the binDir.
- [~] **D.3** **[cluster]** `NetworkAttachmentDefinition` — **flake-authored**
      (`multus.nix`, `services.k3s.manifests`, `.content` so it re-applies until the
      NAD CRD exists). **Collapsed by the macvtap cutover to ONE `cluster-vlan51`
      macvtap NAD** (no IPAM), down from the 16 per-slot static-IPAM bridge NADs.
      Rationale chain: the original single annotation-injection NAD was dropped
      (KubeVirt owns `k8s.v1.cni.cncf.io/networks` and ignores a VM-spec `ips`,
      kubevirt#4564) → reworked to 16 per-slot **bridge** NADs baking each slot IP
      into `static` IPAM → that whole bridge path was then **retired** when
      `br_netfilter` proved to drop routed-in traffic. Under macvtap there is **no
      in-pod DHCP**, so the slot IP no longer comes from the NAD at all: the guest
      DHCPs it from **bt8gw**, keyed on the launcher-pinned per-slot MAC (the bt8gw
      reservation, D-adjacent). Slot identity = MAC, not NAD → one shared NAD serves
      all 16 slots. Lands in a flake-declared `dev-machines` namespace. **Applied +
      verified 2026-06-10** — the VM attached to the shared `cluster-vlan51` NAD and
      DHCP'd `dev-1`'s reservation (`10.97.51.10`). **Residual:** GC the retired
      per-slot bridge NADs if the apply didn't already (k3s won't auto-GC manifest
      removals): `for n in $(seq 1 16); do kubectl -n dev-machines delete net-attach-def cluster-vlan51-dev-$n --ignore-not-found; done`.
- [x] **D.4** **[flake]** Switched the dev-VM manifest in
      `home/modules/dev-machine.nix` from `masquerade` to **multus + macvtap,
      multus-only** (dropped the default pod network; single `macvtap`-bound
      interface on the shared `cluster-vlan51` NAD). The **slot** model drives
      identity: the launcher picks a free slot `dev-N` and patches the VM's
      deterministic per-slot `macAddress` (`02:51:51:00:00:<hex(9+N)>`) — which is
      both the KubeVirt-honored MAC **and** the bt8gw DHCP-reservation key that
      yields the slot's stable `10.97.51.(9+N)` / `dev-N.internal` address.
      `networkName` is the constant shared NAD now. No per-VM registry edit — names
      are static (A.1), occupancy assigned at launch.
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
- [x] **D.7** Acceptance — **PASSED 2026-06-10 (★ Phase 5 proven ★).** From the
      VM: creil `:443` + `:22` reachable (HTTPS clone/registry pull + git-SSH push),
      zeiss `:443` reachable (Attic), WAN reachable, and DNS resolves
      (`dev-1.internal` → `…1033::a`, `creil.internal` → `…1032::35`) via the bt8gw
      resolver. **Isolation holds**: erebonia mgmt `10.97.11.31` `:22`, `:6443`
      (apiserver), `:2049` (NFS) all **time out** — the dev VM cannot reach the
      management VLAN. Egress is exactly the C.3–C.5 allowlist; everything else denied.

## Phase E — `wg-vpn → cluster` rider [bt8gw manual] (maps to plan Phase 4 rider)

_Direct mobile reach — unblocks kubevirt Phase 6 pieces 5–6._

- [-] **E.1** **Optional tightening — not needed for the goal.** The scoped bt8gw
      fw4 `transit → cluster` accept (`saddr = 10.100.10.21` the `mobile` wg peer,
      `daddr` = dev band `10.97.51.10–.25`, **TCP :22 + UDP 60000–61000**) was
      staged as a narrowing. **Mobile access works today without it** (E.3 passed),
      because the existing broad `wg-vpn → cluster` forwarding already admits it.
      Apply this only if that broad forwarding is later narrowed. (One rule covers
      all 16 slots — shared ingress policy, no per-slot rules.)
- [x] **E.2** **Confirmed** — no router6 edit needed on thebeyond. `wg-vpn.accessTo`
      already includes `transit`, so thebeyond forwards `wg-vpn → 10.97.0.0/16`
      (gated by bt8gw fw4); the mosh session reaching `dev-1` end-to-end proves the
      path needed no thebeyond change.
- [x] **E.3** Acceptance — **PASSED 2026-06-10 (★ Goal B proven ★).** From the
      mobile device over `wg-vpn`, `mosh dev@dev-1.internal` connects **directly**
      (no edith hop) and the session **persists across network changes** where a
      plain SSH connection dropped — the roaming property the mosh-in-base-image
      work (P6 pieces 1–4) exists to provide.

## Phase F — verification / acceptance

- [x] **F.1** **Security — confirmed 2026-06-10 (= D.7).** Dev VM is on VLAN 51
      (`10.97.51.10`), multus-only (no flannel NIC), and cannot reach
      management/lab/trusted except the C.3–C.5 allowlist (verified: mgmt
      `10.97.11.31` `:22`/`:6443`/`:2049` time out). erebonia's mgmt identity on
      VLAN 11 is untouched (`uplink.51` carries no host IP; macvtap = host↔guest
      isolation by construction). Residual: F.3 regression sweep (erebonia side).
- [x] **F.2** **Mobile — confirmed 2026-06-10 (= E.3).** Direct `mosh` from the
      `mobile` peer to `dev-1.internal` works without the edith hop, and the session
      survives network changes that drop plain SSH.
- [ ] **F.3** **Regression:** other k3s workloads (plain flannel pods) and the
      existing microVMs/Incus guests on erebonia are unaffected (flannel still
      primary, VLAN 11 mgmt intact).
- [x] **F.4** **Done 2026-06-10.** This checklist + the isolation plan moved
      `plans/ → wip/`; the now-complete `ai-dev-machine-kubevirt-plan.md` moved
      `blocked/ → done/` (its lockdown + mobile dependencies are proven). All
      cross-links updated. Remaining housekeeping (F.3 regression, C.7 as-built
      capture, NAD GC) is tracked above and doesn't block the move.

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
