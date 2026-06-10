# dev-machine VLAN-51: bridge → macvtap cutover

**Status (2026-06-10):** flake side **implemented + eval/build-validated**
(kubevirt.nix, multus.nix, erebonia microvm/default.nix, home/dev-machine.nix).
Pending: cluster apply + bt8gw DHCP reservations + runtime verify (all below).

## Why (root cause, proven 2026-06-10)

The multus dev VMs attach to VLAN 51 via the **bridge CNI onto the host-IP-less
Linux bridge `br51`**. k3s forces `net.bridge.bridge-nf-call-iptables=1` (cni0 +
NetworkPolicy need it), so `br_netfilter` drags br51's *bridged* VLAN-51 frames
through the host's full L3 input/forward/conntrack pipeline. Same-subnet traffic
(bt8gw `.1` → dev-N) stays on the pure-L2 path and works; **cross-subnet /
routed-in traffic (the real `lab → cluster` path, e.g. edith `10.97.21.42` →
dev-N) is silently dropped inside br_netfilter's kernel path** — not by any nft
rule (forward chains are `policy accept`).

Eliminated as fixes (do not revisit): link-scoped route on br51 (helps only
same-subnet), `rp_filter=0` on br51 + uplink.51, a host IP on br51, a `notrack`
rule. Decisive proof: `bridge-nf-call-iptables=0` → routed-in ping works
instantly; `=1` → dies. Can't leave it 0 (k3s needs it; host-netns-global).

**Fix:** take the dev VMs off the host Linux bridge entirely → KubeVirt
**macvtap** binding (macvlan-family, not a bridge → `bridge-nf-call` never
applies). macvlan + KubeVirt *bridge* binding is unsupported (kubevirt#5483: MAC
delegation breaks inbound). Bonus: macvtap gives host↔guest isolation (a stated
goal). **erebonia already uses macvtap for VLAN 50 and VLAN 100 guests** (Incus) —
VLAN 51 was the odd one bridged; this makes it match the house pattern.

## The IP-delivery change (the one real ripple)

bridge binding ran KubeVirt's **in-pod DHCP** to lease the NAD's static-IPAM IP to
the DHCP-only guest. **macvtap does no in-pod DHCP** — the guest DHCPs from the
real VLAN-51 DHCP server (bt8gw, already present). So the slot IP moves from
*NAD static IPAM* → *bt8gw per-slot MAC reservation*. The deterministic per-slot
MAC (`mac_for_slot`: dev-N → hostid `9+N` → `02:51:51:00:00:<hex(9+N)>`, i.e. the
last byte = the IP host octet) makes this exact. `dev-N.internal` A records
(registry `.10`–`.25`) are unchanged — now satisfied by a DHCP reservation.

Consequence: the **16 per-slot NADs collapse to ONE** `cluster-vlan51` macvtap NAD
(slot identity is the launcher-pinned MAC, not the NAD).

## Changes

### A. `hosts/erebonia/k3s/kubevirt.nix` — register the macvtap binding
Add to the KubeVirt CR `spec.configuration` (no feature gate; binding plugins are
default-on since v1.5):
```nix
configuration = {
  developerConfiguration.useEmulation = false;
  network.binding.macvtap.domainAttachmentType = "tap";
};
```

### B. `hosts/erebonia/k3s/multus.nix` — macvtap-cni + one NAD
1. Deploy **macvtap-cni** (DaemonSet = CNI installer + device plugin) and its
   ConfigMap. **Decision:** pin the upstream `kubevirt/macvtap-cni` manifest
   (FOD-fetched, like `kubevirt-operator.yaml`) rather than pulling in CNAO.
   ConfigMap `DP_MACVTAP_CONF`:
   ```json
   [{ "name": "vlan51", "lowerDevice": "uplink.51", "mode": "bridge", "capacity": 16 }]
   ```
   The resource = `macvtap.network.kubevirt.io/<name>` (the `name`, not lowerDevice).
   **`name` MUST be ≤ 10 chars:** the device plugin names each macvtap link
   `<name>Mvp<index>` and Linux caps interface names at 15 (IFNAMSIZ); "Mvp"(3) +
   2-digit index ⇒ 10 is the ceiling. Longer ⇒ Allocate fails with "numerical
   result out of range" (ERANGE). Hence `vlan51`, NOT `cluster-vlan51`. Device-plugin
   binDir matches k3s' `/var/lib/rancher/k3s/data/cni/` (same as the multus chart).
2. Replace `mkSlotNad`/16 NADs with one NAD (its name `cluster-vlan51` is the
   *network* name the launcher references — length-unconstrained, distinct from the
   ≤10-char device-plugin resource):
   ```yaml
   metadata.name: cluster-vlan51
   metadata.annotations."k8s.v1.cni.cncf.io/resourceName": macvtap.network.kubevirt.io/vlan51
   spec.config: '{"cniVersion":"0.3.1","name":"cluster-vlan51","type":"macvtap","mtu":1500}'
   ```
   No IPAM (IP comes from bt8gw DHCP).

### C. `home/modules/dev-machine.nix` — macvtap binding on the VM
- `interfaces[0]`: `bridge = {}` → `binding.name = "macvtap"`. Keep `macAddress`
  (still honored; it's now also the DHCP reservation key).
- networkName: `"$NAMESPACE/cluster-vlan51-$slot"` → `"$NAMESPACE/cluster-vlan51"`
  (single shared NAD). Slot label + MAC pinning unchanged.
- jq patch (lines ~623-624): keep the `macAddress` set; point networkName at the
  single NAD; the interface binding is now structural (`binding.name`), not `bridge`.

### D. `hosts/erebonia/microvm/default.nix` — uplink.51 standalone, drop br51
Mirror the existing `20-uplink.50` / `20-uplink.100` macvtap pattern:
- Delete `netdevs."20-br51"`, `networks."20-br51"` (incl. the link route + the
  `IPv4ReversePathFilter` knob — both were workarounds for the dead-end), and
  `networks."20-vm51-bridge"`.
- Add `networks."20-uplink.51"` = standalone carrier-only (copy `20-uplink.50`).
- Add an unmanaged/carrier match for the macvtap-cni-created devices on uplink.51
  if networkd would otherwise try to manage them (verify device naming first).

### E. bt8gw (out-of-flake, OpenWrt) — DHCP reservations
Add 16 static host reservations on the VLAN-51 DHCP. The MAC's last byte (hex) ==
the IP's last octet (decimal): dev-N → MAC `02:51:51:00:00:<hex(9+N)>` → `10.97.51.(9+N)`:

| slot | MAC | IP |
| --- | --- | --- |
| dev-1 | `02:51:51:00:00:0a` | `10.97.51.10` |
| dev-2 | `02:51:51:00:00:0b` | `10.97.51.11` |
| … | … | … |
| dev-10 | `02:51:51:00:00:13` | `10.97.51.19` |
| dev-16 | `02:51:51:00:00:19` | `10.97.51.25` |

Record in `llm-notes/bt8-gateway-as-built.md`.

## Order of operations
1. Tear down any running dev VMs (`dev-machine down …`) — removing br51 / reslaving
   uplink.51 disrupts the old attachment.
2. Deploy erebonia (A+B+D together). Verify macvtap-cni Running + the node
   advertises `macvtap.network.kubevirt.io/vlan51: 16`.
3. Garbage-collect the retired per-slot bridge NADs (k3s won't auto-GC manifest
   removals): `kubectl -n dev-machines delete net-attach-def -l '' ` won't match;
   do `for n in $(seq 1 16); do kubectl -n dev-machines delete net-attach-def cluster-vlan51-dev-$n --ignore-not-found; done`.
4. bt8gw: add the 16 reservations (E).
5. Apply edith launcher (C): `home-manager switch …#mutantmell@edith`.
6. `dev-machine up <repo>` → boots, macvtap NIC, DHCPs slot IP from bt8gw.

## Verification
- Node: `kubectl describe node erebonia | grep macvtap` shows capacity 16.
- KubeVirt CR has `network.binding.macvtap`.
- In guest: `ip -4 addr` = slot IP (via DHCP), default route via `10.97.51.1`.
- **The goal:** from edith, `ping`/`ssh dev-N.internal` works (routed-in, no
  br_netfilter in the path).
- Regression: flannel pods, VLAN 50/100 Incus macvtap guests, erebonia VLAN-11
  mgmt all unaffected.

## Open items / decisions
- **macvtap-cni deploy:** pinned upstream manifest (recommended) vs CNAO.
- **capacity:** 16 (= slot count) vs headroom (e.g. 32).
- **IPv6:** previously the slot v6 never reached the guest. With macvtap on real
  L2, the guest can SLAAC/DHCPv6 natively off bt8gw's VLAN-51 RA — likely an
  *improvement*; pin the `…1033::N` via a bt8gw DHCPv6 reservation as a follow-up.
- **Confirm** macvtap-cni device-plugin binDir + resource-name-with-dot behavior on
  this k3s before relying on it.
