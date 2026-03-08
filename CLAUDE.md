# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Run all checks (integration tests, unit tests, deploy checks)
# Use run-checks.sh instead of `nix flake check` — the flake has ~66 NixOS
# evaluations which OOM-kills `nix flake check` (single-process eval).
./scripts/run-checks.sh              # sequential (safest)
./scripts/run-checks.sh -j4          # up to 4 in parallel
./scripts/run-checks.sh <name> ...   # run specific checks

# Run a single check
nix build .#checks.x86_64-linux.<name>
# Available checks: router6-ipv6, router6-firewall, router6-firewall-zones,
#   router6-bond-bridge, router6-device-vlans, router6-bridge-vlan-ordering,
#   router6-wan-dhcp, router6-wan-ipv6-pd, router6-dhcpv6, router6-dnat,
#   egress-filter, nftables-dsl, router6-zone-system, router6-firewall-properties,
#   router6-dhcp-config, router6-dnat-properties, router6-assertions,
#   router6-wireguard-config, router6-kresd-config, router6-sysctl-properties,
#   network-helpers, openwrt-config, incus-container, incus-vm,
#   disko-router, disko-vm-host

# Run pure Nix eval tests directly
nix-instantiate --eval --strict tests/lib/<file>.nix

# Run a VM test interactively
nix build .#checks.x86_64-linux.<name>.driverInteractive && ./result/bin/nixos-test-driver

# Build an OpenWrt config (pure Nix, no secrets, no network)
nix build .#openwrtConfigurations.<device-name>

# Build an OpenWrt image (uses upstream Image Builder, not nix store)
nix run .#openwrt-build -- <device-name>
nix run .#openwrt-build -- <device-name> --no-secrets

# Update pinned Image Builder hashes (modifies lib/common/data/openwrt-hashes.json)
# Run this when upgrading to a new OpenWrt release, then commit the hash changes.
nix run .#openwrt-build -- --update-pins               # update all targets
nix run .#openwrt-build -- <device-name> --update-pins # update one device's target
nix run .#openwrt-build -- <device-name> --update      # update hashes + build in one step

# Deploy an OpenWrt image (build + deploy in one step)
nix run .#openwrt-deploy -- <device-name> <device-ip>

# Manual two-step pipeline (composable):
CONFIG_DIR=$(nix build .#openwrtConfigurations.<device-name> --print-out-paths --no-link)
nix run .#openwrt-build -- --config-file "$CONFIG_DIR/build.json" [--secrets-file hosts/openwrt/secrets/wifi.yaml] --output-dir ./out/
$(nix build .#openwrt-deployer --print-out-paths --no-link)/bin/openwrt-deploy <device-ip> ./out/*-sysupgrade.bin

# Show OpenWrt UCI config
nix run .#openwrt-show-config -- <device-name>
```

## Architecture

This is a NixOS flake-based infrastructure project managing a home network with a router, multiple VM hosts, and microVMs. Trails series naming theme (countries, cities, persons).

### Key Directories

- **`modules/router6/default.nix`** — Core router module: zone-based firewall (nftables), systemd-networkd, Kea DHCP4, kresd DNS. Topology-driven: define interfaces and zones, firewall/services are derived.
- **`lib/common/data/network.nix`** — Centralized network registry. All host IPs, subnets, VLANs defined here. Derive addresses with `forHost`, generate `/etc/hosts` with `mkExtraHosts`, DNS records with `mkUnboundLocalData`, egress rules with `mkDualEgressRules`.
- **`lib/nftables.nix`** — Nix DSL for generating nftables rules from attribute sets.
- **`lib/common/default.nix`** — IPv4/IPv6 parsing, egress filter helpers, utility functions.
- **`hosts/`** — Per-host NixOS configurations. VM hosts have `guests/` subdirectories containing microVM definitions.
- **`tests/modules/`** — NixOS VM integration tests (use `pkgs.testers.nixosTest`).
- **`tests/lib/`** — Pure Nix evaluation tests (no VMs needed).
- **`llm-notes/`** — Implementation plans and roadmap. See `feature-roadmap-analysis.md` for the master plan.

### Flake Structure

- `lib.mk-nixos` — Builds NixOS systems with overlays, sops-nix, impermanence, and common module.
- `lib.mk-microvm` — Builds microVM guests with sops-nix, impermanence, and common module.
- `lib.mk-incus-vm` — Builds Incus VM guests with sops-nix, impermanence, common module, and `incus-virtual-machine.nix`.
- `lib.mk-incus-container` — Builds Incus container guests with sops-nix, impermanence, common module, and `lxc-container.nix`.
- Overlays expose custom packages as `pkgs.mmell.*` and library as `pkgs.mmell.lib.*`.
- All modules in `modules/` are auto-discovered via `builtins.readDir`.

### Module Architecture

- **Top-level modules** (`modules/<name>/`) — Define new services or integrations. Designed to be extractable from this flake. No project-specific logic (no hardcoded host names, no impermanence assumptions, no guestDir auto-discovery). Examples: `modules/router6/`, `modules/incus/`.
- **Common modules** (`modules/common/<name>.nix`) — Project-specific coordination and shared configuration across hosts. Handle things like auto-discovery, impermanence integration, builder wiring. Not designed to be extracted. Examples: `modules/common/microvm.nix`, `modules/common/incus.nix`.

### Network Registry Pattern

Hosts access their network config through the registry:

```nix
net = pkgs.mmell.lib.data.network;
inherit (net.forHost "hostname") host zone;
# host.ipv4, host.ipv6, host.cidr4, host.cidr6
# zone.gateway4, zone.gateway6, zone.subnet4, zone.subnet6
```

### Router6 Zone Model

Firewall zones (not a fixed enum — configurable per-deployment):

```nix
router6.zones.<name> = {
  icmpEcho = "enable"|"disable";
  accessTo = [ "other-zone" ];      # forward-chain access
  forwardRules.<target-zone> = [];   # granular forward rules
  inputRules = [];                   # services accessible from this zone
};
```

Topology defines devices (physical, bond, bridge, batman, wireguard) with VLANs, each assigned to a zone.

### Primary Hosts

- **thebeyond** — Router (router6 module, microvm host, impermanence, disko)
- **remiferia** — NAS (ZFS, NFS, microvm host)
- **erebonia** — VM host (Incus, microvm host)

## Testing Patterns

- Pass `system = "x86_64-linux"` explicitly in test configs — `builtins.currentSystem` unavailable in flake pure eval.
- For forward-chain connectivity tests, use `ping` — avoids background listener process issues.
- Background processes in VM tests: `succeed("cmd &")` hangs; redirect output with `>/dev/null 2>&1 &`.
- Use `nc -z` for input-chain tests against running services.

## Secrets

Encrypted with sops-nix using age keys. Secrets live in `hosts/*/secrets/` and decrypt to `/run/secrets/`. Age keys stored in `.keys/` (not in repo).
