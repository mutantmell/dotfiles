# deployd Integration — Implementation Status

## Overview

deployd is a lightweight Rust service for deploying OCI containers at runtime without NixOS rebuilds. It fills the gap between fully-static `oci-containers` (requires rebuild) and imperative `podman run` (no management/audit trail). The spec lives at `temp/dynamic-container-layer.md`.

## Architecture Decisions (Adapted from Spec)

- **Host:** erebonia (bare metal KVM, already runs microVMs + Incus)
- **Network:** `br-deploy` as a local bridge (not VLAN), containers publish ports on host IP
- **Ingress:** Caddy on erebonia with admin API; deployd-helper manages routes dynamically
- **Registry:** Forgejo container registry on creil (CI/CD Phase 6 dependency)
- **Auth:** Keycloak OAuth2 (messeldam) for API; Unix socket SO_PEERCRED + capability token for helper
- **API zone:** management (VLAN 11), alongside messeldam/basel/tharbad
- **Kata fallback:** Prototype first (Phase D0); fall back to rootless Podman if Kata has NixOS issues

## Phase Status

### Phase D0: Prototype Validation — NOT STARTED

Manual validation on erebonia:
1. [ ] Kata Containers with Podman — verify VM boundary
2. [ ] Kata with quadlet file — verify systemd integration
3. [ ] br-deploy bridge with Kata — verify published ports, egress, netavark/nftables
4. [ ] Caddy dynamic route via admin API — verify route add/remove lifecycle
5. [ ] Unix socket between microVM and host — verify SO_PEERCRED

**Output:** Go/no-go on the architecture. Kata fallback to rootless Podman if steps 1-3 fail.

### Phase D1: deployd-helper Module + Binary — COMPLETE

All files created, tests passing, code reviewed.

#### Files Created

| File | Purpose |
|------|---------|
| `packages/deployd-helper/Cargo.toml` | Rust project definition |
| `packages/deployd-helper/Cargo.lock` | Pinned dependencies |
| `packages/deployd-helper/default.nix` | Nix package (`rustPlatform.buildRustPackage`) |
| `packages/deployd-helper/src/main.rs` | Unix socket listener, SO_PEERCRED, capability token auth, message size limit |
| `packages/deployd-helper/src/protocol.rs` | `HelperCommand` enum (Deploy, Teardown, AddFirewallPort, RemoveFirewallPort, AddCaddyRoute, RemoveCaddyRoute, Status) |
| `packages/deployd-helper/src/config.rs` | Configuration from environment variables |
| `packages/deployd-helper/src/executor.rs` | Command execution: quadlet write, systemctl, nft set management, Caddy admin API |
| `packages/deployd-helper/src/validation.rs` | Input validation: registry allowlist, port ranges, hostname suffixes, name format, digest pinning, volume path safety |
| `packages/deployd-helper/src/quadlet.rs` | Podman quadlet file generation |
| `packages/deployd-helper/src/audit.rs` | Append-only structured JSON audit logging |
| `modules/deployd/default.nix` | Extractable NixOS module |
| `modules/common/deployd.nix` | Project-specific wiring (impermanence, registry allowlist) |
| `tests/modules/deployd.nix` | VM integration test |

#### Files Modified

| File | Change |
|------|--------|
| `modules/common/default.nix` | Added `./deployd.nix` import |
| `tests/default.nix` | Added deployd test |
| `flake.nix` | Added `deployd-helper` package; added `self.nixosModules.deployd` to erebonia |

#### Module Options (`deployd.*`)

| Option | Type | Default | Description |
|--------|------|---------|-------------|
| `enable` | bool | false | Enable deployd-helper |
| `package` | package | `pkgs.mmell.deployd-helper` | Helper binary package |
| `registryAllowlist` | list of str | `[]` | Permitted OCI registry prefixes |
| `hostnameAllowlist` | list of str | `[]` | Permitted hostname suffixes for Caddy routes |
| `portRange.min` | port | 1024 | Minimum host port |
| `portRange.max` | port | 65535 | Maximum host port |
| `socketPath` | str | `/run/deployd/deployd.sock` | Unix socket path |
| `stateDir` | str | `/var/lib/deployd` | Persistent state directory |
| `auditLogPath` | str | `/var/log/deployd/audit.log` | Audit log path |
| `capabilityTokenFile` | str | (required) | Path to capability token file |
| `allowedUid` | int | (required) | UID permitted to connect |
| `bridge.name` | str | `br-deploy` | Bridge device name |
| `bridge.subnet` | str | `10.100.0.1/24` | Bridge subnet |
| `caddy.enable` | bool | true | Enable Caddy integration |
| `caddy.adminUrl` | str | `http://localhost:2019` | Caddy admin API URL |
| `caddy.serverName` | str | `deployd` | Caddy server block name for routes |
| `caddy.listenAddress` | str | `""` | Caddy HTTPS listen address |
| `kata.enable` | bool | true | Enforce Kata runtime (guarded by nixpkgs option availability) |

#### Security Features Implemented

- **SO_PEERCRED** on every connection — rejects unauthorized UIDs (root allowed for operational debugging; token still required)
- **Capability token** validated on every message
- **Message size limit** (1 MiB) prevents DoS
- **Registry allowlist** checked independently by helper
- **Digest pinning** required for all image references
- **Container name validation** — alphanumeric/hyphen/underscore only, no dots/slashes/special chars
- **Volume path validation** — absolute paths only, no `..`, blocks `/etc /boot /proc /sys /dev /nix`
- **Port range enforcement**
- **Hostname suffix allowlist** for Caddy routes
- **nftables table** scoped to bridge with `policy accept` — only filters traffic TO `br-deploy`
- **systemd hardening** — CAP_NET_ADMIN + CAP_DAC_OVERRIDE only, ProtectSystem=strict, RestrictAddressFamilies, etc.
- **Append-only audit log** on host filesystem (outside microVM trust boundary)

#### Test Coverage

- 19 Rust unit tests (name validation, image validation, port ranges, volume paths, hostname validation, quadlet generation)
- 1 VM integration test (bridge creation, address assignment, nftables table/set, helper service, socket, directories, Podman, firewall set manipulation)
- All 4 host evaluations pass (thebeyond, calvard, erebonia, remiferia)

### Phase D2: deployd API MicroVM — NOT STARTED

Dependencies: Phase D0 (go/no-go), Phase D1 (complete)

Tasks:
- [ ] Choose microVM name (Trails-series Erebonia city: Roer, Ordis, Legram, Bareahard, Celdic, Ymir, Jurai, Heimdallr)
- [ ] Register deployd microVM in `lib/common/data/network.nix` (management zone, VLAN 11)
- [ ] Create microVM guest config under `hosts/erebonia/microvm/guests/<name>/`
- [ ] Build deployd API binary (Rust/axum): HTTP API, OAuth2 validation, Unix socket client
- [ ] Add Keycloak client in messeldam config
- [ ] Add forward rules on thebeyond: DMZ→management (saint-arkh→deployd), trusted→management
- [ ] Wire virtiofs share for Unix socket, egress rules, DNS entries
- [ ] Configure capability token generation at microVM boot

### Phase D3: CI/CD Integration — NOT STARTED

Dependencies: CI/CD Phases 1-3 + Phase 6 (container registry on creil)

Tasks:
- [ ] Add deploy step to CI workflow
- [ ] Add deployd CLI tool for manual deployments
- [ ] Update `llm-notes/plans/ci-cd-plan.md` Phase 6

### Phase D4: Game Servers + Headscale — NOT STARTED

Dependencies: Headscale deployment

Tasks:
- [ ] Add VLAN 41 bridge (br41) to erebonia
- [ ] Create game zone on thebeyond
- [ ] Per-container bridge selection in deployd
- [ ] Headscale subnet router for game zone
- [ ] Caddy listener on `tailscale0`
- [ ] iSCSI block storage add-on (Suspend/Resume/AttachVolume/DetachVolume commands)
- [ ] Storage pool configuration and validation

## Deferred Items (from Code Review)

These items were identified in the code review but are intentionally deferred:

| Item | Deferred To | Rationale |
|------|-------------|-----------|
| Suspend/Resume/AttachVolume/DetachVolume protocol variants | Phase D4 | iSCSI addon is Phase D4 scope |
| Storage pool NixOS option + device path validation | Phase D4 | Coupled to iSCSI addon |
| `block_volume` field handling in executor | Phase D4 | Field exists as placeholder (`Option<String>`) |
| Multi-threaded connection handling | Future | Single-client homelab use; deployd API is the only client |

## Network Changes Summary

| Change | File | Phase |
|--------|------|-------|
| Add deployd microVM to management zone | `lib/common/data/network.nix` | D2 |
| DMZ→management forward: saint-arkh→deployd:443 | `hosts/thebeyond/router.nix` | D2 |
| trusted→management forward: operator→deployd:443 | `hosts/thebeyond/router.nix` | D2 |
| Add VLAN 41 bridge to erebonia | `hosts/erebonia/default.nix` | D4 |
| Create game zone (split from untrusted) | `hosts/thebeyond/router.nix` | D4 |

## Reference Patterns

- Saint-arkh microVM config: `hosts/erebonia/microvm/guests/saint-arkh/`
- Egress filtering: `pkgs.mmell.lib.nftables.mkEgressFilter` + `net.mkEgressRules`
- Network registry: `lib/common/data/network.nix` — `forHost`, `mkExtraHosts`
- Module pattern: `modules/incus/default.nix` (extractable) + `modules/common/incus.nix` (wiring)
