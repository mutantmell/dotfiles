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

All files created, tests passing, code reviewed and hardened.

#### Files Created

| File | Purpose |
|------|---------|
| `packages/deployd-helper/Cargo.toml` | Rust project definition |
| `packages/deployd-helper/Cargo.lock` | Pinned dependencies |
| `packages/deployd-helper/default.nix` | Nix package (`rustPlatform.buildRustPackage`) |
| `packages/deployd-helper/src/main.rs` | Unix socket listener, SO_PEERCRED, capability token auth, bounded message reads |
| `packages/deployd-helper/src/protocol.rs` | `HelperCommand` enum (Deploy, Teardown, AddFirewallPort, RemoveFirewallPort, AddCaddyRoute, RemoveCaddyRoute, Status) |
| `packages/deployd-helper/src/config.rs` | Configuration from environment variables |
| `packages/deployd-helper/src/executor.rs` | Command execution: quadlet write, systemctl, nft set management, Caddy admin API |
| `packages/deployd-helper/src/validation.rs` | Input validation: registry allowlist, port ranges, hostname suffixes, name format, digest pinning, volume path safety, env var sanitization |
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
| `stateDir` | str | `/var/lib/deployd` | Reserved for future state (Phase D4 iSCSI); not used at runtime |
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
- **Capability token** validated on every message with constant-time comparison (`subtle` crate)
- **Bounded message reads** — `BufReader::take()` enforces 1 MiB hard limit before buffering, preventing memory exhaustion from unbounded lines
- **Registry allowlist** checked independently by helper
- **Digest pinning** required for all image references
- **Container name validation** — alphanumeric/hyphen/underscore only, no dots/slashes/special chars; enforced on all commands (Deploy, Teardown, AddCaddyRoute, RemoveCaddyRoute)
- **Volume path validation** — absolute paths only, no `..`, blocks `/etc /boot /proc /sys /dev /nix`
- **Port range enforcement** — on Deploy ports and standalone AddFirewallPort/RemoveFirewallPort/AddCaddyRoute commands
- **Hostname suffix allowlist** for Caddy routes — enforced on both Deploy ingress and standalone AddCaddyRoute
- **Environment variable sanitization** — keys must be alphanumeric+underscore, values must not contain newlines (prevents quadlet file injection)
- **nftables table** scoped to bridge with `policy accept` — only filters traffic TO `br-deploy`
- **Minimal capabilities** — `CAP_NET_ADMIN` only (for nft set manipulation); no `CAP_DAC_OVERRIDE`
- **Scoped polkit rule** — deployd-helper authorized for `manage-units` and `reload-daemon` only
- **`NoNewPrivileges = true`** — prevents privilege escalation via execve
- **`ProtectSystem = strict`** — filesystem read-only except explicitly listed paths
- **`UMask = 0027`** — quadlet files created 0640 (no world-readable container configs)
- **`RestrictAddressFamilies`** — AF_UNIX (socket), AF_NETLINK (nft), AF_INET (Caddy admin API) only
- **`RestrictNamespaces = true`** and **`SystemCallFilter = @system-service ~@privileged`**
- **Append-only audit log** on host filesystem (outside microVM trust boundary)
- **Native quadlet persistence** — persistent containers use `/etc/containers/systemd/` (Podman's native persistent directory); runtime-only containers use `/run/containers/systemd/` (tmpfs)

#### Filesystem Access (exhaustive)

| Path | Access | Purpose |
|------|--------|---------|
| `/run/containers/systemd/` | read-write (group `deployd-helper`, mode 0775) | Runtime quadlet files |
| `/etc/containers/systemd/` | read-write (group `deployd-helper`, mode 0775) | Persistent quadlet files (native Podman location) |
| `/run/deployd/` | read-write (owner `deployd-helper`, mode 0750) | Unix socket |
| `/var/log/deployd/` | read-write (owner `deployd-helper`, mode 0750) | Audit log |

#### Test Coverage

- 26 Rust unit tests (name validation, image validation, port ranges, volume paths, hostname validation, env var validation, quadlet generation)
- 1 VM integration test (bridge creation, address assignment, nftables table/set, helper service, socket, directories, Podman, firewall set manipulation, socket protocol/auth verification, audit log verification)
- All 4 host evaluations pass (thebeyond, calvard, erebonia, remiferia)

#### Changes from Original Implementation

These changes were made during code review to improve security and correctness:

| Change | Rationale |
|--------|-----------|
| Added `validate_name()` to Teardown, AddCaddyRoute, RemoveCaddyRoute | Original only validated names in Deploy; standalone commands could inject paths or systemd unit names |
| Added `validate_port_range()` to AddFirewallPort, RemoveFirewallPort, AddCaddyRoute | Original only validated ports in Deploy; standalone commands accepted any u16 |
| Added `validate_hostname()` to AddCaddyRoute | Original only validated hostnames in Deploy ingress; standalone command had no hostname check |
| Added `validate_env()` for environment variable keys/values | Original wrote env vars directly to quadlet files; newlines in values could inject systemd unit directives |
| Replaced hand-rolled token comparison with `subtle::ConstantTimeEq` | Original used `!=` (timing side-channel); hand-rolled XOR loop could be optimized away by compiler; `subtle` uses `#[inline(never)]` + compiler barriers |
| Replaced `BufReader::lines()` with `take().read_line()` | Original buffered entire lines before size check; malicious client could send multi-GB line without `\n` to exhaust memory |
| Persistent quadlets use native `/etc/containers/systemd/` | Original wrote to custom `{stateDir}/quadlets/` and copied to runtime dir on boot; this duplicated Podman's native persistence mechanism and had no cleanup for stale entries |
| Removed `restore_persistent_quadlets()` | No longer needed — native `/etc/containers/systemd/` is scanned by quadlet generator at boot automatically |
| Dropped `CAP_DAC_OVERRIDE` | Original needed it to write to root-owned quadlet dirs; changed dirs to group `deployd-helper` with mode 0775 instead. CAP_DAC_OVERRIDE bypasses ALL filesystem permission checks system-wide |
| Added polkit rule for systemctl | Original had no polkit authorization; `systemctl daemon-reload/start/stop` would fail as non-root user. Scoped to `manage-units` and `reload-daemon` only |
| Set `NoNewPrivileges = true` | Original set `false` ("required for capability use"); only needed for CAP_DAC_OVERRIDE interaction. CAP_NET_ADMIN ambient capabilities work fine with NoNewPrivileges |
| Set `UMask = 0027` | Original used default 0022; quadlet files (containing env vars with potential secrets) were world-readable at 0644. Now created as 0640 |
| Removed `stateDir` from runtime | Original allocated `/var/lib/deployd` with ReadWritePaths, tmpfiles, impermanence, and env var. Nothing uses it at runtime. NixOS option retained for Phase D4 (iSCSI state) |
| Kept `libc` SO_PEERCRED instead of nightly `peer_cred()` | Evaluated switching to nightly Rust for `#![feature(peer_credentials_unix_socket)]` to eliminate the only `unsafe` block. Feature tracking issue (#42839) is nearly 10 years old with no stabilization momentum — poor foundation to depend on. The `libc` code is correct, minimal, and idiomatic |
| Removed `libc` → restored `libc` | Briefly attempted to use stdlib `UnixStream::peer_cred()`, discovered it requires nightly (unstable since 2017). Beta Rust also doesn't work — `#![feature]` gates are nightly-only. Reverted to `libc::getsockopt` |

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
- [ ] Re-add `stateDir` to runtime (ReadWritePaths, tmpfiles, impermanence) for iSCSI state

## Deferred Items (from Code Review)

These items were identified in the code review but are intentionally deferred:

| Item | Deferred To | Rationale |
|------|-------------|-----------|
| Suspend/Resume/AttachVolume/DetachVolume protocol variants | Phase D4 | iSCSI addon is Phase D4 scope |
| Storage pool NixOS option + device path validation | Phase D4 | Coupled to iSCSI addon |
| `block_volume` field handling in executor | Phase D4 | Field exists as placeholder (`Option<String>`) |
| `stateDir` runtime wiring (ReadWritePaths, tmpfiles, impermanence) | Phase D4 | Nothing uses it at runtime until iSCSI state |
| Multi-threaded connection handling | Future | Single-client homelab use; deployd API is the only client |
| Nightly Rust for safe `peer_cred()` | When stabilized | Feature #42839 has no stabilization momentum; `libc` code is correct |

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
