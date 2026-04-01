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

- [x] **1.1 Split router6/default.nix into sub-files**
      Split from 2586 lines into focused sub-modules. Final structure:

  ```
  modules/router6/
    default.nix        — imports, option declarations, assertions (~810 lines)
    lib.nix            — shared helpers: topology processing, address parsing,
                         DHCP builders, nftables helpers (~320 lines)
    networking.nix     — systemd-networkd links, netdevs, networks, sysctl, RA config
    dhcp.nix           — Kea DHCP4/6 server config
    dns.nix            — kresd config, DHCP DNS extraction
    firewall.nix       — nftables ruleset generation (zones, input, forward, NAT, egress)
    dyndns.nix         — dynamic DNS service + timer
  ```

      Assertions stayed in default.nix alongside the option definitions (not a separate
      file) to keep them visible when adding/changing config options. lib.nix imports
      nft internally rather than threading it through every sub-module.

- [x] **1.2 Extract common module list in flake.nix builders**
      Extracted `commonModules` binding referenced by all 4 builders (mk-nixos,
      mk-microvm, mk-incus-vm, mk-incus-container).

### Phase 2: Library consolidation

- [ ] **2.1 Consolidate IP parsing into lib/common/**
      Two independent implementations exist:
  - `lib/common/default.nix` — `parse-ipv4`, `parse-cidr4` (IPv4 only, no validation)
  - `modules/router6/lib.nix` — `parseIPAddress`, `parseCIDR` (dual-stack)
    Merge into a single `lib/common/network-parsing.nix` with the router6 version as base.
    Add input validation. Router6 imports from lib instead of defining its own.

- [x] **2.2 Remove duplicate mkExtraHosts / mkHostsFileEntries**
      Removed `mkHostsFileEntries` (identical to `mkExtraHosts`). Updated all references
      and removed associated tests.

- [ ] **2.3 Move display/formatting out of network.nix**
      Lines 139-302 contain ~160 lines of `pad`, `summary`, `markdown`, `hostinfoPad`,
      `hostinfoSummary`, `hostinfoMarkdown` etc. Move to a separate file
      (`lib/common/data/network-display.nix`) or into the apps that consume them
      (`apps/netinfo.nix`, `apps/hostinfo.nix`).

- [ ] **2.4 Document mkEgressFilter (lib/common) vs router6 egressPolicy split**
      `lib/common/default.nix` has `mkEgressFilter` (raw nftables string template).
      Router6 has `firewall.egressPolicy` + `egressRules` (structured DSL-based).
      mkEgressFilter is actively used by 12 microVM guest configs across calvard,
      erebonia, and remiferia, plus the egress-filter test. The two approaches serve
      different contexts: mkEgressFilter for standalone microVM guests, router6's
      egressPolicy for the router itself. Document this split clearly and consider
      whether a lighter shared module could unify the interface.

### Phase 3: Test coverage

- [x] **3.1 Add network registry tests**
      Added `tests/lib/network-registry.nix` with 30 pure eval tests covering: networks
      (subnet/gateway derivation), mkHost (address fields), hosts (flattened lookup
      including hex encoding), forHost (structured lookup + error on unknown), allHostDomains.

- [ ] **3.2 Add OpenWrt UCI rendering tests**
      `tests/lib/openwrt-config.nix` already covers config builder functions
      (mkDeviceConfig, mkSecretsMap, mkConfigFiles). What's missing is unit tests
      for `lib/openwrt/uci.nix` (230 lines) — the UCI rendering layer itself.
      Add pure eval tests for UCI attribute-to-string conversion and edge cases.

### Phase 4: Automation & cleanup

- [x] **4.1 Auto-derive host eval checks from nixosConfigurations**
      Replaced hardcoded host list with `lib.mapAttrs'` over `self.nixosConfigurations`.

- [ ] **4.2 Add deploy-rs nodes for calvard, erebonia, remiferia, kernviter, angbar**
      Only thebeyond has a deploy-rs definition. Add the other five active hosts.

- [ ] **4.3 Remove or document commented-out hosts**
      `azoth` (Raspberry Pi) and `arcus` (Steam Deck / Jovian) are commented out in
      flake.nix with no explanation. Either remove them or add a comment explaining
      their status and when they might return.

- [x] **4.4 Document the incus two-pass type probing**
      Already documented at `modules/common/incus.nix:33-42`.

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

- [x] **5.3 Document OpenWrt secret marker pattern**
      Already documented at `lib/openwrt/default.nix:230-232` with examples.
