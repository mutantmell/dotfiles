# Dev-Machine Lockdown + Mobile Access — Cross-Plan Sequencing

**Last updated: 2026-06-09.** A navigation/sequencing index, **not** a plan — it
has no lifecycle status of its own. It ties together the plans that finish two
goals and records the order their phases must land in _relative to each other_:

- **Goal A — secure the devcontainers** (the LLM dev-machine VMs): off the
  management VLAN, router-confined, no host adjacency.
- **Goal B — reach a running dev machine directly from a mobile device** (no
  edith hop).

Plans referenced:

- [`blocked/ai-dev-machine-kubevirt-plan.md`](blocked/ai-dev-machine-kubevirt-plan.md)
  — the dev-machine platform/workflow. Phases 1–4 done; **P5** (lockdown) and
  **P6** (mobile) are the goals here.
- [`plans/workload-network-isolation-plan.md`](plans/workload-network-isolation-plan.md)
  — the network design P5/P6 are blocked on (the `cluster`/VLAN 51 zone).
- [`plans/cluster-vlan-bringup-checklist.md`](plans/cluster-vlan-bringup-checklist.md)
  — the execution checklist for the isolation plan's critical-path slice
  (Phases A–F). **This is the thing you actually work.**

---

## Where things stand

**Done**

- kubevirt **P1→P4** — platform, devcontainer, devpod wiring, scoped push
  credential. The chain works end-to-end; the sandbox holds exactly one scoped
  push credential.
- kubevirt **P6 pieces 1–4** — mobile session ergonomics (mosh in the base
  image, zellij in the dev image, multi-key AccessCredentials, attach helper).
  Works **today** over the edith-jump interim (commit 63452a0).
- Docs — isolation plan + bring-up checklist + the cross-plan reconciliation.

- **Checklist A** (isolation P1) — `cluster`/VLAN 51 registry zone + **16 named
  dev slots** `dev-1`..`dev-16` (`10.97.51.10`..`.25`), DNS auto-derived. Static
  names, dynamic occupancy (the Phase D launcher assigns a free slot's IP to each
  ephemeral VM — no registry edit per machine). Pure flake, no behavior change.
  (No router6 change: a thebeyond `cluster` zone stub was drafted then dropped —
  nothing on thebeyond names a bt8gw-owned zone, so it was inert; see checklist
  A.2.) Landed 2026-06-08 (checks green).

- **Checklist B flake-half** (isolation P2 L2) — erebonia `uplink.51` added to the
  `uplink` trunk + a **host-IP-less `br51`** bridge (mirrors `br21`, not `br11`);
  `trustedInterfaces` untouched, so the host keeps zero VLAN-51 surface. Inert
  until bt8gw carries tag 51. Landed 2026-06-09 (erebonia config evals clean).
- **Checklist B.1/C.1 bt8gw L3** — VLAN 51 **terminates live on bt8gw**
  (`ping 10.97.51.1` answers, 2026-06-09). UCI for the full bt8gw half (B.1 + C)
  staged in `temp/BT8-gw-cluster-vlan51-additions.uci` + as-built note.

**Remaining** — a single critical path through the isolation plan, executed via
the bring-up checklist. **Next up: finish Checklist C** (bt8gw fw4 cluster zone +
egress allowlist — the staged UCI's §2/§2b, bt8gw-manual) and verify B.2, then
**Checklist D**. The sharp item is C.3: the `cluster → app` egress must enforce
the creil/zeiss-only allowlist (not the broad zone-pair accept the Phase-5.A fw4
gotcha produces) — verify on the device. Goal A and Goal B share most of it;
Goal B adds one step.

---

## Sequence

```
DONE ───────────────────────────────────────────────────────────────────────
  kubevirt:  P1 ─ P2 ─ P3 ─ P4        (sandbox works; scoped push cred)
             P6 pieces 1–4            (mosh / zellij / multi-key / attach)
  docs:      isolation plan + checklist + reconciliation

REMAINING ───────────────────────────────────────────────────────────────────

   checklist A            checklist B + C              checklist D
   registry / zone  ───►  L2 plumbing  +        ───►   KubeVirt multus-only
   [flake]                bt8gw cluster zone           attach + pin IP/DNS
   (no behavior;          [L2 + bt8gw manual]          + cutover access path
    independently         (stands up VLAN 51            [cluster + flake]
    mergeable)             end-to-end)                        │
        │                       │                             ▼
   isol P1                 isol P2 (L2 + fw4)         ★━━━ GOAL A: SECURE ━━━★
                           (NOT the flannel           = kubevirt P5 done
                            redirect — deferred)             │
                                                             ▼
                                                       checklist E
                                                       wg-vpn → cluster rider
                                                       [bt8gw manual]
                                                       isol P4 rider
                                                             │
                                                             ▼
                                                 ★━━ GOAL B: MOBILE (direct) ━━★
                                                 = kubevirt P6 pieces 5–6 done
                                                 (pieces 1–4 already landed)
                                                             │
                                                             ▼
                                                       checklist F (verify both)
```

---

## Ordered cross-plan checklist

| #    | Step                                                                                                                                                 | Maps to                      | Surface             | Depends on                                                                 |
| ---- | ---------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------- | ------------------- | -------------------------------------------------------------------------- |
| 1 ✅ | **Checklist A** — `cluster`/VLAN 51 in registry, 16 named dev slots `dev-1`..`dev-16`, DNS via `mkUnboundLocalData` (no router6 stub — see A.2)      | isolation **P1**             | `[flake]`           | **Done 2026-06-08** (checks green)                                         |
| 2 ◑  | **Checklist B** — tag 51: bt8gw `br0` bridge-vlan → mesh → erebonia `uplink.51` + host-IP-less `br51`                                                | isolation **P2** (L2)        | `[L2 + flake]`      | flake half **done** 2026-06-09; bt8gw L3 live; B.2 mesh-tag verify pending |
| 3 ◑  | **Checklist C** — bt8gw: terminate VLAN 51 (gw `.1`), cluster fw4 zone, egress allowlist (`creil:{22,443}`, `zeiss:443`, DNS, WAN), `cluster→* deny` | isolation **P2** (fw4)       | `[bt8gw manual]`    | C.1 live; C.2–C.7 staged (UCI §2/§2b), verify on device                    |
| 4    | **Checklist D** — Multus + bridge CNI, NAD on `br51`, dev-VM manifest `masquerade→multus-only`, pin IP/DNS, rework access path to direct SSH         | isolation **P4**             | `[cluster + flake]` | A, B, C                                                                    |
| ★    | **GOAL A — devcontainer secured**                                                                                                                    | **= kubevirt P5**            | —                   | D complete                                                                 |
| 5    | **Checklist E** — bt8gw fw4 `transit→cluster` for `mobile` peer `10.100.10.21` :22 + UDP 60000–61000 → dev band                                      | isolation **P4 rider**       | `[bt8gw manual]`    | D                                                                          |
| ★    | **GOAL B — direct mobile access**                                                                                                                    | **= kubevirt P6 pieces 5–6** | —                   | E complete (pieces 1–4 done)                                               |
| 6    | **Checklist F** — verify security + mobile + no flannel/microVM regression; move isolation docs to `wip/`                                            | both                         | —                   | D, E                                                                       |

---

## Ordering notes & risks

- **A is the safe first move** — pure flake, no behavior change, independently
  mergeable. Everything else builds on its addressing.
- **B and C together = "VLAN 51 live end-to-end"** — both touch bt8gw and stand
  up the same segment; do them as one push. **C must be verified before D**, or
  the VM can clone/pull nothing.
- **D is the cutover** — switching `masquerade → multus-only` changes how
  operators reach the VM (`kubectl port-forward` hack → direct SSH to
  `dev-N.internal`, the slot the VM occupies). It is the one step where the
  working flow changes shape, and it is the security milestone.
- **The bt8gw work (B.1, C, E) is the operational risk concentration** — manual
  UCI/LuCI, not flake-testable; `run-checks.sh` won't catch mistakes there.
  Capture each as a `temp/*.uci` + as-built note (the Phase-5.A pattern; see
  [`bt8-gateway-as-built.md`](bt8-gateway-as-built.md)).

---

## Deferred — NOT on either goal's path

Real parts of the isolation plan, but **out of scope** for these two goals; do
them later, independently. Don't let them creep into this slice.

- **erebonia host-side flannel-egress redirect** (`ip rule` + policy routing +
  masquerade). The dev VM is multus-only and bypasses flannel, so it needs none
  of this. Required only when **WAN is removed from VLAN 11** (for general pods).
- **LB-IPAM (MetalLB)** for routable _service_ VIPs. Not needed to reach the VM.
- **NetworkPolicy default-deny** — inert for a multus-only VM (no flannel NIC for
  kube-router to govern); bt8gw fw4 is the sole enforcer. Apply later only if
  pod-network workloads share the namespace.
- **Dynamic-pool IPAM** (Whereabouts vs bt8gw DHCP) — named hosts are
  static+registry; resolve only when an unpinned pool is actually wanted.
