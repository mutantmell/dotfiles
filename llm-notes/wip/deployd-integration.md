# deployd Integration — Implementation Status

## Overview

deployd is a lightweight Rust service for deploying OCI containers at runtime without NixOS rebuilds. It fills the gap between fully-static `oci-containers` (requires rebuild) and imperative `podman run` (no management/audit trail). The spec lives at `temp/dynamic-container-layer.md`.

## Architecture Decisions (Adapted from Spec)

- **Host:** erebonia (bare metal KVM, already runs microVMs + Incus)
- **Network:** `br-deploy` as a local bridge (not VLAN), containers publish ports on host IP
- **Ingress:** Caddy on erebonia with admin API; deployd-helper manages routes dynamically
- **Bridge isolation:** Static nftables rules restrict br-deploy inbound traffic to Caddy only. Caddy route presence/absence is the sole dynamic access control. deployd-helper has no kernel-level network authority (no CAP_NET_ADMIN). See "Architecture Change: Static Bridge Isolation" below.
- **Registry:** Forgejo container registry on creil (CI/CD Phase 6 dependency)
- **Auth:** Keycloak OAuth2 (messeldam) for API; Unix socket SO_PEERCRED + capability token for helper
- **API zone:** management (VLAN 11), alongside messeldam/basel/tharbad
- **Kata fallback:** Prototype first (Phase D0); fall back to rootless Podman if Kata has NixOS issues

### Architecture Change: Static Bridge Isolation (Post-D1 Review)

**Decision:** Remove all nftables set manipulation from deployd-helper. Replace the dynamic `allowed_ports` set with a static nftables rule that restricts br-deploy inbound traffic to Caddy only. Drop CAP_NET_ADMIN from the helper.

**Rationale:**

The original design used a dynamic nftables `allowed_ports` set — deployd-helper added port entries when deploying containers and removed them on teardown, requiring CAP_NET_ADMIN. However:

1. **CAP_NET_ADMIN is unscoped.** It grants authority over ALL network configuration on the host: every nftables table, routing tables, interfaces. deployd-helper only needs to manage one set, but if compromised, an attacker could rewrite the entire host network stack.

2. **The nftables set is redundant with Caddy.** Caddy route presence/absence already controls which services are reachable. If no Caddy route exists for a container's port, external traffic cannot reach it. The nftables set was belt-and-suspenders for the same check.

3. **Static isolation is stronger and simpler.** A boot-time nftables rule "only Caddy can reach br-deploy" provides kernel-level defense-in-depth without giving deployd-helper kernel-level network authority. The principle: **static policy in the kernel, dynamic policy in Caddy, no elevated capabilities in the helper.**

4. **The split still makes sense.** Even without CAP_NET_ADMIN, deployd-helper is privileged — it writes quadlet files and controls systemctl. The deployd API → deployd-helper Unix socket boundary keeps the HTTP/OAuth2 attack surface in an unprivileged microVM.

5. **Non-HTTP workloads (Phase D4) don't change this.** Game servers use a separate bridge (br41) in the "game" zone on thebeyond. That zone's firewall policy is managed by router6 (static, boot-time), not by deployd-helper. For L4 proxying, caddy-l4 or an equivalent proxy handles dynamic routing without kernel-level access.

6. **Additional ingress paths (e.g., cloud host → WireGuard → langport → Caddy → br-deploy) don't change this.** The static isolation rule is origin-agnostic — it restricts which process can reach br-deploy, not where the traffic came from. Upstream routing/zone policy is thebeyond's responsibility.

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

#### D1b: Static Bridge Isolation — COMPLETE

Removed dynamic nftables port management and standalone Caddy route commands from deployd-helper. Replaced with static Caddy-only bridge isolation. Integrated Caddy route lifecycle into Deploy/Teardown commands.

**Binary changes (completed):**

- [x] Removed `AddFirewallPort`, `RemoveFirewallPort`, `AddCaddyRoute`, `RemoveCaddyRoute` from `HelperCommand` enum
- [x] Removed all nft-related code (`nft()` helper, firewall port handlers, config fields)
- [x] Removed standalone Caddy route handlers — route management integrated into `deploy()` and `teardown()`
- [x] Added `upstream_port: u16` to `IngressConfig` for explicit proxy target
- [x] Deploy creates Caddy route if `ingress` is set (with rollback on failure)
- [x] Teardown removes Caddy route best-effort (tolerates missing routes)
- [x] Removed `block_volume: Option<String>` placeholder from `ContainerDefinition`
- [x] Made `validate_port_range()` and `validate_hostname()` private (no standalone callers)

**Module changes (completed):**

- [x] Replaced dynamic `allowed_ports` nftables set with static forward-chain isolation (drop all unsolicited inbound to bridge)
- [x] Removed all capabilities (no `CAP_NET_ADMIN`, no `CAP_DAC_OVERRIDE` — zero extended capabilities)
- [x] Removed `AF_NETLINK` from `RestrictAddressFamilies`
- [x] Removed `DEPLOYD_NFT_PATH` and `DEPLOYD_NFTABLES_TABLE` environment variables
- [x] Removed `stateDir` option (unused placeholder)

**Test changes (completed):**

- [x] Replaced nftables set manipulation tests with static isolation verification (forward chain drop rule)
- [x] Kept socket protocol, audit log, bridge, and directory tests

#### Files Created

| File                                        | Purpose                                                                                                                                     |
| ------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `packages/deployd-helper/Cargo.toml`        | Rust project definition                                                                                                                     |
| `packages/deployd-helper/Cargo.lock`        | Pinned dependencies                                                                                                                         |
| `packages/deployd-helper/default.nix`       | Nix package (`rustPlatform.buildRustPackage`)                                                                                               |
| `packages/deployd-helper/src/main.rs`       | Unix socket listener, SO_PEERCRED, capability token auth, bounded message reads                                                             |
| `packages/deployd-helper/src/protocol.rs`   | `HelperCommand` enum (Deploy, Teardown, AddCaddyRoute, RemoveCaddyRoute, Status)                                                            |
| `packages/deployd-helper/src/config.rs`     | Configuration from environment variables                                                                                                    |
| `packages/deployd-helper/src/executor.rs`   | Command execution: quadlet write, systemctl, Caddy admin API                                                                                |
| `packages/deployd-helper/src/validation.rs` | Input validation: registry allowlist, port ranges, hostname suffixes, name format, digest pinning, volume path safety, env var sanitization |
| `packages/deployd-helper/src/quadlet.rs`    | Podman quadlet file generation                                                                                                              |
| `packages/deployd-helper/src/audit.rs`      | Append-only structured JSON audit logging                                                                                                   |
| `modules/deployd/default.nix`               | Extractable NixOS module                                                                                                                    |
| `modules/common/deployd.nix`                | Project-specific wiring (impermanence, registry allowlist)                                                                                  |
| `tests/modules/deployd.nix`                 | VM integration test                                                                                                                         |

#### Files Modified

| File                         | Change                                                                        |
| ---------------------------- | ----------------------------------------------------------------------------- |
| `modules/common/default.nix` | Added `./deployd.nix` import                                                  |
| `tests/default.nix`          | Added deployd test                                                            |
| `flake.nix`                  | Added `deployd-helper` package; added `self.nixosModules.deployd` to erebonia |

#### Module Options (`deployd.*`)

| Option                | Type        | Default                      | Description                                                     |
| --------------------- | ----------- | ---------------------------- | --------------------------------------------------------------- |
| `enable`              | bool        | false                        | Enable deployd-helper                                           |
| `package`             | package     | `pkgs.mmell.deployd-helper`  | Helper binary package                                           |
| `registryAllowlist`   | list of str | `[]`                         | Permitted OCI registry prefixes                                 |
| `hostnameAllowlist`   | list of str | `[]`                         | Permitted hostname suffixes for Caddy routes                    |
| `portRange.min`       | port        | 1024                         | Minimum host port                                               |
| `portRange.max`       | port        | 65535                        | Maximum host port                                               |
| `socketPath`          | str         | `/run/deployd/deployd.sock`  | Unix socket path                                                |
| `auditLogPath`        | str         | `/var/log/deployd/audit.log` | Audit log path                                                  |
| `capabilityTokenFile` | str         | (required)                   | Path to capability token file                                   |
| `allowedUid`          | int         | (required)                   | UID permitted to connect                                        |
| `bridge.name`         | str         | `br-deploy`                  | Bridge device name                                              |
| `bridge.subnet`       | str         | `10.100.0.1/24`              | Bridge subnet                                                   |
| `caddy.enable`        | bool        | true                         | Enable Caddy integration                                        |
| `caddy.adminUrl`      | str         | `http://localhost:2019`      | Caddy admin API URL                                             |
| `caddy.serverName`    | str         | `deployd`                    | Caddy server block name for routes                              |
| `caddy.listenAddress` | str         | `""`                         | Caddy HTTPS listen address                                      |
| `kata.enable`         | bool        | true                         | Enforce Kata runtime (guarded by nixpkgs option availability)   |

#### Security Features Implemented

- **SO_PEERCRED** on every connection — rejects unauthorized UIDs (root allowed for operational debugging; token still required)
- **Capability token** validated on every message with constant-time comparison (`subtle` crate)
- **Bounded message reads** — `BufReader::take()` enforces 1 MiB hard limit before buffering, preventing memory exhaustion from unbounded lines
- **Registry allowlist** checked independently by helper
- **Digest pinning** required for all image references
- **Container name validation** — alphanumeric/hyphen/underscore only, no dots/slashes/special chars; enforced on all commands (Deploy, Teardown, AddCaddyRoute, RemoveCaddyRoute)
- **Volume path validation** — absolute paths only, no `..`, blocks `/etc /boot /proc /sys /dev /nix`
- **Port range enforcement** — on Deploy ports and standalone AddCaddyRoute commands
- **Hostname suffix allowlist** for Caddy routes — enforced on both Deploy ingress and standalone AddCaddyRoute
- **Environment variable sanitization** — keys must be alphanumeric+underscore, values must not contain newlines (prevents quadlet file injection)
- **Static bridge isolation** — boot-time nftables rule restricts br-deploy inbound to Caddy only; no dynamic set manipulation
- **Zero extended capabilities** — no `CAP_NET_ADMIN`, no `CAP_DAC_OVERRIDE`; deployd-helper operates as an unprivileged user with polkit-scoped systemctl access
- **Scoped polkit rule** — deployd-helper authorized for `manage-units` and `reload-daemon` only
- **`NoNewPrivileges = true`** — prevents privilege escalation via execve
- **`ProtectSystem = strict`** — filesystem read-only except explicitly listed paths
- **`UMask = 0027`** — quadlet files created 0640 (no world-readable container configs)
- **`RestrictAddressFamilies`** — AF_UNIX (socket), AF_INET (Caddy admin API) only
- **`RestrictNamespaces = true`** and **`SystemCallFilter = @system-service ~@privileged`**
- **Append-only audit log** on host filesystem (outside microVM trust boundary)
- **Native quadlet persistence** — persistent containers use `/etc/containers/systemd/` (Podman's native persistent directory); runtime-only containers use `/run/containers/systemd/` (tmpfs)

#### Filesystem Access (exhaustive)

| Path                       | Access                                         | Purpose                                           |
| -------------------------- | ---------------------------------------------- | ------------------------------------------------- |
| `/run/containers/systemd/` | read-write (group `deployd-helper`, mode 0775) | Runtime quadlet files                             |
| `/etc/containers/systemd/` | read-write (group `deployd-helper`, mode 0775) | Persistent quadlet files (native Podman location) |
| `/run/deployd/`            | read-write (owner `deployd-helper`, mode 0750) | Unix socket                                       |
| `/var/log/deployd/`        | read-write (owner `deployd-helper`, mode 0750) | Audit log                                         |

#### Test Coverage

- 26 Rust unit tests (name validation, image validation, port ranges, volume paths, hostname validation, env var validation, quadlet generation)
- 1 VM integration test (bridge creation, address assignment, static nftables isolation, helper service, socket, directories, Podman, socket protocol/auth verification, audit log verification)
- All 4 host evaluations pass (thebeyond, calvard, erebonia, remiferia)

#### Changes from Original Implementation

These changes were made during code review to improve security and correctness:

| Change                                                                    | Rationale                                                                                                                                                                                                                                                                                                           |
| ------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Added `validate_name()` to Teardown                                        | Original only validated names in Deploy; Teardown could inject paths or systemd unit names                                                                                                                                                                                                                          |
| Added `validate_env()` for environment variable keys/values               | Original wrote env vars directly to quadlet files; newlines in values could inject systemd unit directives                                                                                                                                                                                                          |
| Replaced hand-rolled token comparison with `subtle::ConstantTimeEq`       | Original used `!=` (timing side-channel); hand-rolled XOR loop could be optimized away by compiler; `subtle` uses `#[inline(never)]` + compiler barriers                                                                                                                                                            |
| Replaced `BufReader::lines()` with `take().read_line()`                   | Original buffered entire lines before size check; malicious client could send multi-GB line without `\n` to exhaust memory                                                                                                                                                                                          |
| Persistent quadlets use native `/etc/containers/systemd/`                 | Original wrote to custom `{stateDir}/quadlets/` and copied to runtime dir on boot; this duplicated Podman's native persistence mechanism and had no cleanup for stale entries                                                                                                                                       |
| Removed `restore_persistent_quadlets()`                                   | No longer needed — native `/etc/containers/systemd/` is scanned by quadlet generator at boot automatically                                                                                                                                                                                                          |
| Dropped `CAP_DAC_OVERRIDE`                                                | Original needed it to write to root-owned quadlet dirs; changed dirs to group `deployd-helper` with mode 0775 instead. CAP_DAC_OVERRIDE bypasses ALL filesystem permission checks system-wide                                                                                                                       |
| Added polkit rule for systemctl                                           | Original had no polkit authorization; `systemctl daemon-reload/start/stop` would fail as non-root user. Scoped to `manage-units` and `reload-daemon` only                                                                                                                                                           |
| Set `NoNewPrivileges = true`                                              | Original set `false` ("required for capability use"); only needed for CAP_DAC_OVERRIDE interaction. No ambient capabilities remain, so no conflict                                                                                                                                                                  |
| Set `UMask = 0027`                                                        | Original used default 0022; quadlet files (containing env vars with potential secrets) were world-readable at 0644. Now created as 0640                                                                                                                                                                             |
| Removed `stateDir` from runtime                                           | Original allocated `/var/lib/deployd` with ReadWritePaths, tmpfiles, impermanence, and env var. Nothing uses it at runtime. NixOS option later also removed (see below).                                                                                                                                            |
| Kept `libc` SO_PEERCRED instead of nightly `peer_cred()`                  | Evaluated switching to nightly Rust for `#![feature(peer_credentials_unix_socket)]` to eliminate the only `unsafe` block. Feature tracking issue (#42839) is nearly 10 years old with no stabilization momentum — poor foundation to depend on. The `libc` code is correct, minimal, and idiomatic                  |
| Removed `libc` → restored `libc`                                          | Briefly attempted to use stdlib `UnixStream::peer_cred()`, discovered it requires nightly (unstable since 2017). Beta Rust also doesn't work — `#![feature]` gates are nightly-only. Reverted to `libc::getsockopt`                                                                                                 |
| Removed `AddFirewallPort`/`RemoveFirewallPort` commands and all nft usage | Replaced dynamic nftables `allowed_ports` set with static Caddy-only bridge isolation. CAP_NET_ADMIN is unscoped (grants authority over ALL host network config); static isolation + Caddy dynamic routing achieves the same goal without elevated capabilities. See "Architecture Change: Static Bridge Isolation" |
| Dropped `CAP_NET_ADMIN`                                                   | No longer needed — deployd-helper no longer calls nft. Zero extended capabilities.                                                                                                                                                                                                                                  |
| Removed `AF_NETLINK` from `RestrictAddressFamilies`                       | AF_NETLINK was only needed for nft commands. Tighter socket allowlist.                                                                                                                                                                                                                                              |
| Removed standalone `AddCaddyRoute`/`RemoveCaddyRoute` commands            | Subsumed by Deploy/Teardown lifecycle. Deploy creates Caddy route if `ingress` is set; Teardown removes it best-effort. Eliminates extra protocol surface with no concrete use case.                                                                                                                                 |
| Added `upstream_port` to `IngressConfig`                                  | Deploy needs to know which port to proxy to when creating Caddy routes. Explicit field avoids magic conventions (e.g. "use first port mapping").                                                                                                                                                                     |
| Removed `block_volume: Option<String>` from `ContainerDefinition`         | Phase D4 placeholder — dead code carried through every message, test, and serialization path. Trivial to re-add when needed.                                                                                                                                                                                        |
| Removed `stateDir` NixOS option                                           | Previously retained for Phase D4, but the option itself was dead — not wired to any tmpfiles, ReadWritePaths, or env var. Re-add when D4 needs it.                                                                                                                                                                  |

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

Non-HTTP workloads (game servers) use a separate bridge (br41) in the "game" zone on thebeyond. Zone-level firewall policy is managed by router6 (static, boot-time). For L4 proxying of non-HTTP traffic, evaluate caddy-l4 (maintained by Matt Holt) or equivalent. deployd-helper does NOT need CAP_NET_ADMIN for this — the same pattern applies: static policy in the kernel (router6 zones), dynamic policy in the proxy (caddy-l4 or similar).

Tasks:

- [ ] Add VLAN 41 bridge (br41) to erebonia
- [ ] Create game zone on thebeyond (router6 zone model)
- [ ] Per-container bridge selection in deployd
- [ ] Headscale subnet router for game zone
- [ ] Evaluate caddy-l4 for non-HTTP L4 proxying (game server traffic)
- [ ] Caddy listener on `tailscale0`
- [ ] iSCSI block storage add-on (Suspend/Resume/AttachVolume/DetachVolume commands)
- [ ] Storage pool configuration and validation
- [ ] Add `stateDir` option and `block_volume` protocol field for iSCSI state (removed in D1b)

## Deferred Items (from Code Review)

These items were identified in the code review but are intentionally deferred:

| Item                                                               | Deferred To     | Rationale                                                            |
| ------------------------------------------------------------------ | --------------- | -------------------------------------------------------------------- |
| Suspend/Resume/AttachVolume/DetachVolume protocol variants         | Phase D4        | iSCSI addon is Phase D4 scope                                        |
| Storage pool NixOS option + device path validation                 | Phase D4        | Coupled to iSCSI addon                                               |
| `block_volume` field + `stateDir` option                           | Phase D4        | Removed in D1b (dead code); re-add when iSCSI state is needed        |
| Multi-threaded connection handling                                 | Future          | Single-client homelab use; deployd API is the only client            |
| Nightly Rust for safe `peer_cred()`                                | When stabilized | Feature #42839 has no stabilization momentum; `libc` code is correct |

## Network Changes Summary

| Change                                           | File                          | Phase |
| ------------------------------------------------ | ----------------------------- | ----- |
| Add deployd microVM to management zone           | `lib/common/data/network.nix` | D2    |
| DMZ→management forward: saint-arkh→deployd:443   | `hosts/thebeyond/router.nix`  | D2    |
| trusted→management forward: operator→deployd:443 | `hosts/thebeyond/router.nix`  | D2    |
| Add VLAN 41 bridge to erebonia                   | `hosts/erebonia/default.nix`  | D4    |
| Create game zone (split from untrusted)          | `hosts/thebeyond/router.nix`  | D4    |

## Reference Patterns

- Saint-arkh microVM config: `hosts/erebonia/microvm/guests/saint-arkh/`
- Egress filtering: `pkgs.mmell.lib.nftables.mkEgressFilter` + `net.mkEgressRules`
- Network registry: `lib/common/data/network.nix` — `forHost`, `mkExtraHosts`
- Module pattern: `modules/incus/default.nix` (extractable) + `modules/common/incus.nix` (wiring)
