# Workload networking and trust boundaries

Status: selected Arteria architecture with dated BT8 runtime observations retained as evidence. Configuration is not proof of live cutover; verify the accepted gateway before changing policy.

The network registry in `lib/common/data/network.nix` owns names, VLANs, addresses, and gateway placement. Derive configuration from it rather than copying tables from old migration plans. The selected routing owners are NixOS thebeyond and Arteria; OpenWrt provides Layer-2 wireless transit. The historical BT8-gateway routing owner applies only to the pre-cutover path and retained physical rollback. APP and cluster traffic require policy at the actual office gateway as well as thebeyond's router6 zones.

Dev-machine VMs use a shared `cluster-vlan51` Multus/macvtap attachment over erebonia's host-IP-less `uplink.51`, bypassing flannel. Deterministic MACs and registry-derived DHCP reservations at the active office gateway give slots `dev-1` through `dev-16` stable identities. Arteria enforces VM egress in the selected design (the BT8 firewall owns the historical pre-cutover path); Kubernetes NetworkPolicy does not govern this secondary data plane.

Ordinary flannel pods have a different path: their traffic is masqueraded through erebonia's management identity unless an explicit egress design changes it. A pod is not isolated like a VLAN-51 VM merely because it belongs to the cluster. Keep less-trusted general workloads off this path until egress and NetworkPolicy acceptance succeeds. CI namespaces have their own declared policies; audit the actual runner backend before drawing conclusions about a job.

Avoid bridge-netfilter coupling on guest VLANs: use host-IP-less macvtap carriers where suitable and keep host management on its own interface. Host-to-child L2 communication is a macvlan/macvtap limitation; validate required routed and storage paths rather than assuming a bridge replacement is transparent. Choose bridge/private/VEPA mode against the trust boundary and test same-zone communication explicitly.

Dated pre-Arteria deployment observations are in [BT8 observed state](bt8-observed-state.md). [OpenWrt operations](../openwrt-operations.md) describes evidence capture and cutover boundaries. Proposed pod egress redirection must preserve pod/Service routes and keep its host VLAN-51 interface outside trusted interfaces, with default-drop host INPUT and no inbound host services except explicitly justified control traffic. Test direct VLAN-51 client access to the egress IP independently of pod policy. Future egress redirection, service VIPs, NAS hardening, and multi-node designs are proposed work, not deployed guarantees.

## Media VPN destination routes

Arcus already has a wg-media client and both gateways permit HTTPS to Oracion.
The current client allowedIPs still includes DMZ and management destinations but
omits APP, where Oracion now resides. [The remaining VPN task](https://forgejo.internal/mutantmell-net/dotfiles/issues/235)
is to correct registry-derived destination routes and validate access, not enroll
the client again. The configured endpoint is LAN-local (`10.97.30.1:51820`) and
DNS uses the local DHCP resolver; offsite use would require a separate endpoint
and DNS design. Angbar has no repository-managed WireGuard client, although its
server-side laptop peer exists; [client setup](https://forgejo.internal/mutantmell-net/dotfiles/issues/237)
remains distinct from this media VPN.
