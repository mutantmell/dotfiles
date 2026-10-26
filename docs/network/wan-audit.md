# Recurring external WAN exposure audit

Run after changes to WAN input/forwarding, WireGuard exposure, public ingress or the ISP edge path, and after an edge deployment whose acceptance includes those changes. Internal tests and rendered-rule checks complement this audit; they cannot establish what an off-network client actually reaches.

## Establish the expected surface first

Review the deployed commit's `hosts/thebeyond/router.nix`, the generated rules from `modules/router6/firewall.nix`, any other router modules, and the live ISP/CPE forwarding configuration. Record the deployed SHA and known intentional differences. At this checkout the external zone has no general input/forward access, echo is disabled, and **wg-vpn UDP 59362** plus **wg-media UDP 51820** request `openFirewall`. Do not copy the retired three-tunnel port list: 38506 still appears in an outbound egress allowlist, which does not itself create an inbound listener. Recompute this inventory when configuration changes.

Inventory both router-local and forwarded exposure. IPv6 control traffic needed for neighbor discovery/error handling/PMTU is distinct from echo or application services; do not disable required ICMPv6 to make a scan appear silent. A wildcard listener is not automatically WAN-reachable, and a denied scan is not proof no listener exists.

Use a laptop on cellular data or another authorized off-network machine. Disconnect its homelab VPN during the unauthenticated scans; confirm the route really goes over the external network. Scan only public addresses assigned to this fleet and within the agreed operator test window. Obtain the current public IPv4, router GUA and any explicitly in-scope forwarded host GUAs from trusted operator state; do not assume a hostname or delegated prefix stayed unchanged. If a family is unavailable, record it as not tested rather than passed.

## TCP, UDP and echo checks

The following are examples for one verified target. Set `audit_target` to that owned public address and `audit_dir` to a private directory outside Git. Use a separate filename set per target/address family; the limits below bound retries, not a promise of exact scan duration.

```bash
mkdir -m 700 "$audit_dir"
sudo nmap -sS -Pn -p- --max-retries 1 -T3 \
  -oN "$audit_dir/tcp-v4.txt" "$audit_target"
sudo nmap -sU -Pn --top-ports 1000 --max-retries 1 -T3 \
  -oN "$audit_dir/udp-top-v4.txt" "$audit_target"
sudo nmap -sU -Pn -p 59362,51820 --max-retries 1 -T3 \
  -oN "$audit_dir/udp-wg-v4.txt" "$audit_target"
ping -c 5 -W 2 "$audit_target"
```

If IPv6 is in scope, repeat against each explicitly authorized GUA using `nmap -6` and `ping -6`, with distinct `*-v6.txt` outputs. Repeat the explicit UDP-port scan with the actual approved WireGuard ports if they change; keep it separate from the top-ports scan. Do not scan a whole delegated prefix.

Compare results with the expected surface. With the current no-public-TCP policy, an open TCP port or an unexpected responding UDP service is a finding that must be explained before acceptance. `closed`, `filtered`, and `open|filtered` express different observations; investigate unexpected responses against the intended reject/drop policy, but do not equate silence with demonstrated security. In particular, an unauthenticated WireGuard probe cannot distinguish a working silent listener from a dropped packet. Echo loss is expected under the current policy but proves neither application filtering nor functional IPv6 error handling.

## Prove authorized access and inspect the router

After the unauthenticated scans, use an authorized WireGuard peer to verify a fresh handshake and an intended routed destination, then test that an unrelated destination remains denied. Test each enabled tunnel using its own peer; a wg-vpn success does not accept wg-media. Exercise IPv6 routing if supported. If the test device's tunnel was initially disconnected, restore its original state afterward.

From an operator session on the router, capture the listening socket inventory and active ruleset to private files:

```bash
sudo ss -tlnp > "$audit_dir/router-tcp-listeners.txt"
sudo ss -ulnp > "$audit_dir/router-udp-listeners.txt"
sudo nft list ruleset > "$audit_dir/router-ruleset.txt"
```

These commands run on the router, not the external scanner; create a separate private `audit_dir` there. Examine rule ordering, default verdicts, intended WireGuard input accepts, external forwarding and any NAT rules against the deployed configuration. Resolve unexplained drift and rerun affected external tests after a fix. Do not flush the live firewall to diagnose a scan.

## Record acceptance

Keep target/address family, external vantage point, UTC time, deployed commit, expected surface, scan outputs, socket/ruleset captures, keyed handshake/allowed-and-denied results, exceptions and retest outcome in encrypted/private operator storage. Addresses, endpoints and rulesets can disclose topology, so attach only a redacted summary to an issue or PR. Preserve the existing recovery path until the agreed checks pass. Document what was not tested; this is a dated exposure observation, not a permanent guarantee.
