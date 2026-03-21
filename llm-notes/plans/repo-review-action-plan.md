# Repository Review — Action Plan

Review date: 2026-03-21

## Summary

The repo is well-structured with strong test coverage, clean module boundaries, and a
solid topology-driven router design. The main issues are: a monolithic router6 module,
duplicated/incomplete library code, accumulated presentation logic in the data layer,
and some gaps in test coverage and deployment automation.

## Priorities

1. **Structural maintainability** — Split large files, reduce duplication
2. **Library consolidation** — One IP parser, one egress helper, clean data/display split
3. **Test coverage gaps** — Network registry and OpenWrt config builders are untested
4. **Automation & DX** — Auto-derive checks, deploy-rs coverage, dead code cleanup

## Action Items

### Phase 1: Reduce friction in the largest files

- [ ] **1.1 Split router6/default.nix into sub-files**
  Current: 2573 lines in one file covering options, IP parsing, topology, DHCP, DNS,
  DynDNS, firewall, systemd-networkd, assertions.
  Target structure:
  ```
  modules/router6/
    default.nix        — imports + top-level enable option
    options.nix        — all mkOption declarations (zones, topology, dns, firewall, dyndns)
    lib.nix            — internal helpers (parseCIDR, parseIPAddress, flattenTopology,
                         getEffectiveAddresses, address family helpers, ipv4ToInt)
    networking.nix     — systemd-networkd links, netdevs, networks, RA config
    dhcp.nix           — Kea DHCP4/6 subnet generation
    dns.nix            — kresd config, DHCP DNS extraction, DNS interception
    firewall.nix       — nftables ruleset generation (zones, input, forward, NAT, egress)
    dyndns.nix         — dynamic DNS service + timer
    assertions.nix     — all assertion blocks
  ```

- [ ] **1.2 Extract common module list in flake.nix builders**
  `mk-nixos`, `mk-microvm`, `mk-incus-vm`, `mk-incus-container` all repeat the same
  5-module import list (sops-nix, impermanence, common, promtail-client,
  node-exporter-client). Extract to a `commonModules` binding and reference it.

### Phase 2: Library consolidation

- [ ] **2.1 Consolidate IP parsing into lib/common/**
  Two independent implementations exist:
  - `lib/common/default.nix` — `parse-ipv4`, `parse-cidr4` (IPv4 only, no validation)
  - `modules/router6/default.nix` lines 901-998 — `parseIPAddress`, `parseCIDR` (dual-stack)
  Merge into a single `lib/common/network-parsing.nix` with the router6 version as base.
  Add input validation. Router6 imports from lib instead of defining its own.

- [ ] **2.2 Remove duplicate mkExtraHosts / mkHostsFileEntries**
  `network.nix` defines both `mkExtraHosts` (line 196) and `mkHostsFileEntries` (line 291)
  which produce identical output. Remove one and alias the other.

- [ ] **2.3 Move display/formatting out of network.nix**
  Lines 139-302 contain ~160 lines of `pad`, `summary`, `markdown`, `hostinfoPad`,
  `hostinfoSummary`, `hostinfoMarkdown` etc. Move to a separate file
  (`lib/common/data/network-display.nix`) or into the apps that consume them
  (`apps/netinfo.nix`, `apps/hostinfo.nix`).

- [ ] **2.4 Reconcile mkEgressFilter (lib/common) vs router6 egressPolicy**
  `lib/common/default.nix` has `mkEgressFilter` (raw nftables string template).
  Router6 has `firewall.egressPolicy` + `egressRules` (structured DSL-based).
  Evaluate whether `mkEgressFilter` is still used; if only by non-router hosts,
  consider migrating those to a lighter shared module or documenting the split.

### Phase 3: Test coverage

- [ ] **3.1 Add network registry tests**
  `lib/common/data/network.nix` (363 lines) has zero tests. Add pure eval tests in
  `tests/lib/network-registry.nix` covering:
  - `forHost` returns correct IPs/zones
  - `mkExtraHosts` output format
  - `mkEgressRules` dual-stack expansion
  - Host alias resolution
  - Error on unknown host

- [ ] **3.2 Add OpenWrt config builder tests**
  `lib/openwrt/default.nix` (1112 lines) and `uci.nix` (230 lines) have no tests.
  Add pure eval tests for UCI rendering and at least one device-type config snapshot.

### Phase 4: Automation & cleanup

- [ ] **4.1 Auto-derive host eval checks from nixosConfigurations**
  Currently hardcoded to 4 hosts (lines 486-489 of flake.nix). Replace with:
  ```nix
  lib.mapAttrs' (name: _: lib.nameValuePair "host-eval-${name}" (mkHostCheck name))
    self.nixosConfigurations
  ```

- [ ] **4.2 Add deploy-rs nodes for calvard, erebonia, remiferia**
  Only thebeyond has a deploy-rs definition. Add the other three deployed hosts.

- [ ] **4.3 Remove or document commented-out hosts**
  `azoth` (Raspberry Pi) and `arcus` (Steam Deck / Jovian) are commented out in
  flake.nix with no explanation. Either remove them or add a comment explaining
  their status and when they might return.

- [ ] **4.4 Document the incus two-pass type probing**
  `common/incus.nix` builds a VM system first to read `incus-guest.type`, then
  rebuilds as container if needed. Add a comment explaining the laziness dependency
  so future changes don't break it.

- [ ] **4.5 Audit scheduled-deploy module usage**
  Verify whether `modules/scheduled-deploy/` is used by any host. If not, decide
  whether to keep it (for future use) or remove it.

### Phase 5: Larger improvements (optional / future)

- [ ] **5.1 Add network registry validation**
  Check for duplicate VLAN IDs, duplicate host IDs within a zone, VLAN ID range (1-4094).
  Surface errors at eval time with clear messages.

- [ ] **5.2 Dual-stack rule helper**
  Add a helper to generate matching IPv4 + IPv6 firewall rules from a single template,
  reducing the boilerplate of writing every rule twice in router configs.

- [ ] **5.3 Document OpenWrt secret marker pattern**
  The `{_secret = "key.name"}` convention in OpenWrt configs is undocumented.
  Add a section to docs or a comment block in `lib/openwrt/default.nix`.
