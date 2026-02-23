# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Test Commands

```bash
# Run all checks (integration tests, unit tests, deploy checks)
nix flake check --print-build-logs

# Run a single check
nix build .#checks.x86_64-linux.<name>
# Available checks: router6-ipv6, router6-firewall, router6-firewall-zones,
#   router6-bond-bridge, router6-device-vlans, router6-bridge-vlan-ordering,
#   egress-filter, router6-yggdrasil, nftables-dsl, router6-firewall-snapshot,
#   yggdrasil-firewall-snapshot, router6-zone-system, network-helpers,
#   disko-router, disko-vm-host

# Run pure Nix eval tests directly
nix-instantiate --eval --strict tests/lib/<file>.nix

# Run a VM test interactively
nix build .#checks.x86_64-linux.<name>.driverInteractive && ./result/bin/nixos-test-driver
```

## Architecture

This is a NixOS flake-based infrastructure project managing a home network with a router, multiple VM hosts, and microVMs. Norse mythology naming theme throughout.

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

- `lib.mk-nixos` — Builds NixOS systems with overlays, sops-nix, and common module.
- `lib.mk-microvm` — Builds microVM guests with sops-nix, impermanence, and common module.
- Overlays expose custom packages as `pkgs.mmell.*` and library as `pkgs.mmell.lib.*`.
- All modules in `modules/` are auto-discovered via `builtins.readDir`.

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

- **yggdrasil** — Router (router6 module, microvm host, impermanence, disko)
- **jotunheimr** — NAS (ZFS, NFS, microvm host)
- **muspelheim** — VM host (Incus, microvm host)

## Testing Patterns

- Pass `system = "x86_64-linux"` explicitly in test configs — `builtins.currentSystem` unavailable in flake pure eval.
- For forward-chain connectivity tests, use `ping` — avoids background listener process issues.
- Background processes in VM tests: `succeed("cmd &")` hangs; redirect output with `>/dev/null 2>&1 &`.
- Use `nc -z` for input-chain tests against running services.

## Secrets

Encrypted with sops-nix using age keys. Secrets live in `hosts/*/secrets/` and decrypt to `/run/secrets/`. Age keys stored in `.keys/` (not in repo).
