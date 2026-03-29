# cc-sandbox: Claude Code Sandbox Orchestrator

## Context

cc-sandbox began as a test harness for validating deployd — the dynamic container
deployment service. The goal was to pick a real product feature (Claude Code sandboxes)
that would exercise the full deployd stack end-to-end: Kata containers, CNI networking,
the API/helper split, deployd-exec privilege model, Keycloak auth, and container
lifecycle management. That validation succeeded — deployd D0 is complete, the
architecture is sound, and the path to D1c (containerd gRPC), D3 (CI/CD integration),
and other deployd consumers (Forgejo action runners, scheduled task workers) is clear.

The prototype cc-sandbox (Phases 1-5) served its purpose as a deployd test client. It
was always expected that the test harness code might be throwaway. What we learned from
using it informed the design of cc-sandbox as a real product — Phase 7 is that design,
not a rewrite of a failure but the first proper design of cc-sandbox informed by
hands-on experience with the deployd platform it depends on.

## Prototype Architecture (Phases 1-5)

The prototype used a daemon + CLI architecture with privilege separation. Phase 7
replaces this with a single CLI tool — see "Phase 7: Repo-Centric Design" for the
current design.

```
  [edith (10.97.21.42, lab zone)]
    cc-sandbox CLI (runs as mutantmell)
      - rebuild-image: nix build + skopeo push (privileged)
      - create/teardown/list/ssh: talks to daemon via Unix socket

    cc-sandbox daemon (systemd service, cc-sandbox user)      ← REMOVED in Phase 7
      - Unix socket: /run/cc-sandbox/cc-sandbox.sock
      - Holds: Keycloak creds, Forgejo token (sops)
      - State: /var/lib/cc-sandbox/state.json
      - NO nix, skopeo, or SSH access
      |
      | HTTPS (client credentials grant → Bearer token)
      v
    [roer.internal] → deployd-api → deployd-helper → containerd/Kata
      |
      | deploy response includes container IP
      v
    [sandbox container on deploy-dmz (10.97.100.x, gateway 10.97.100.1)]
      - CNI macvlan on deploy-dmz VLAN, own IP
      - Clones SANDBOX_REPO_URL on startup (git credential helper for auth)
      - User SSH keys authorized in image
      - Claude Code (nixpkgs) + nix develop for project dependencies
      - Resource-limited (memory + CPU via nerdctl flags)
```

## Language: Python

cc-sandbox is a thin orchestration layer — it makes HTTP calls to Keycloak, deployd-api,
and Forgejo, and shells out to `nix build`, `skopeo`, and `nix copy` for image and store
management. Python with `requests` and standard library is sufficient and much faster to
develop than Rust.

Packaging: `stdenv.mkDerivation` with `makeWrapper` around `python3.withPackages`, following the `openwrt-builder` pattern.

## Privilege Separation (Prototype — superseded by Phase 7)

The prototype daemon/CLI split provided privilege separation. Phase 7 eliminates the
daemon entirely — the CLI reads secrets directly from sops-nix-managed files and makes
all API calls itself. No privilege separation is needed because there is only one
principal (the user).

## Prerequisite: deployd-helper returns container IP on inspect — COMPLETE

deployd-helper's Inspect command retrieves the container IP. The implementation
has gone through several iterations:

1. ~~`nerdctl inspect`~~ — failed due to nerdctl v2 rootful/rootless namespace confusion
2. **Current:** `deployd-exec inspect` uses `ctr` (containerd's native gRPC CLI)
   to find the container by nerdctl name label, then scans CNI host-local IPAM
   state files for the IP. Works but involves fragile shell parsing (see
   "Containerd gRPC Consolidation" in `deployd-integration.md` for planned fix).

Returns IP in the `HelperResponse.data` field. deployd-api forwards `data` to
HTTP callers. cc-sandbox reads IP from the deploy response.

Planned: Phase D1c will replace the entire inspect path by having deployd-helper
invoke CNI directly during container creation. The IP will be a return value from
CNI ADD, eliminating the need for a separate inspect step. See
`deployd-integration.md` "Architecture Change: Replace nerdctl with Containerd
gRPC" for details.

**Files modified:**

- `modules/deployd/default.nix` — `deployd-exec inspect` subcommand (ctr + CNI state scan)
- `packages/deployd-helper/src/executor.rs` — calls deployd-exec inspect, parses result

## Phase 1-3: Python Package — COMPLETE (prototype, superseded by Phase 7)

Single Python file (`cc_sandbox.py`) with daemon + CLI. Phase 7 eliminates the daemon
and restructures the CLI around project profiles.

**Daemon commands (via Unix socket):**

- `create [--repo <url>]` — generate hostname, fork repo on Forgejo, deploy container with env vars for repo clone, DNS, git auth, upstream remote
- `teardown <name>` — destroy sandbox via deployd-api, remove from state
- `list` — return active sandboxes from state
- `info <name>` — return single sandbox details
- `set-digest` — record image digest (sent by CLI after push). Daemon is sole state writer.

**CLI commands (talk to daemon via socket):**

- `rebuild-image` — `nix build` + `skopeo push` + send digest to daemon via socket. Runs as calling user.
- `ssh <name>` — query daemon for IP, exec SSH (runs as calling user)

**Files created:**

- `packages/cc-sandbox/cc_sandbox.py` — daemon + CLI
- `packages/cc-sandbox/default.nix` — Nix package

**Files modified:**

- `flake.nix` — added `cc-sandbox` package
- `packages/claude-sandbox-image/default.nix` — entrypoint clones `SANDBOX_REPO_URL` if set

**Features:**

- Trails-themed hostname generation (30 adjectives x 30 nouns = 900 combinations)
- OIDC client credentials grant (confidential client, not password grant) with token caching
- JSON state file with flock locking
- Separate Forgejo URL config (`CC_SANDBOX_FORGEJO_URL`, defaults to `https://<registry>`)
- skopeo TLS verification via CA cert (falls back to `--tls-verify=false` only if no cert configured)
- Container env vars for repo cloning (no SSH from daemon into containers)
- Resource limits (memory + CPU) passed through to deployd deploy call

## Phase 4: Forgejo Integration — COMPLETE (in Phase 1-3)

Repo forking via Forgejo API is integrated into the daemon's `create` handler. The fork
URL is passed as `SANDBOX_REPO_URL` env var to the container, and the container entrypoint
handles cloning. Phase 7 moves forking to `init` (one-time registration).

## Phase 5: NixOS Wiring on edith — COMPLETE (prototype, superseded by Phase 7)

Phase 7 replaces this NixOS module with a home-manager profile. The system service,
system user, and sops secret declarations below are removed. The NixOS host config
reduces to `environment.systemPackages` for the CLI.

**New files:**

- `hosts/calvard/incus/guests/edith/modules/cc-sandbox.nix` — NixOS module with options:
  - `services.cc-sandbox.enable` + apiUrl, authUrl, registry, forgejoUrl, caCert, flakePath, flakeAttr
  - `dnsServers` — DNS server IPs passed to sandbox containers (written to /etc/resolv.conf at boot)
  - `memoryLimit` (default "4g") — memory limit per sandbox container
  - `cpuLimit` (default "2") — CPU limit per sandbox container
  - Systemd service: runs as `cc-sandbox` system user, hardened (ProtectSystem, NoNewPrivileges, restricted address families/syscalls)
  - Daemon PATH restricted to just the cc-sandbox package (no nix/skopeo/ssh)
  - `mutantmell` added to `cc-sandbox` group (socket access)
  - Sops secrets: client-secret, forgejo-token (token readable by group for CLI image push)
  - Note: edith has a persistent XFS root — no impermanence block needed
  - Env vars for daemon: secret file paths, API URLs, registry, CA cert, DNS servers, memory/CPU limits
  - Env vars for CLI: socket path, registry, flake path/attr (system-wide via environment.variables)

**Modified files:**

- `hosts/calvard/incus/guests/edith/default.nix` — import module, enable with production URLs, `dnsServers = ["10.97.100.1"]`
- `hosts/calvard/incus/guests/edith/sops.nix` — declare cc-sandbox secrets

**Manual steps (before deploy):**

- Create "cc" user on Forgejo (creil), generate personal access token with write:repository + write:package
- Create `cc-sandbox` confidential client in Keycloak (homelab realm):
  - Client authentication: ON (confidential)
  - Grant type: client credentials only
  - Map the `deploy` group to the client's service account (so tokens carry the group claim)
- Create `hosts/calvard/incus/guests/edith/secrets/secrets.yaml` with sops:
  - `cc-sandbox-client-secret`, `cc-sandbox-forgejo-token`

## Phase 6: Update deployd integration doc — COMPLETE

- `llm-notes/wip/deployd-integration.md` — D0 marked complete, deployd-helper protocol updated with memory/cpus fields

## Container Image Details

The sandbox container image (`packages/claude-sandbox-image/default.nix`) provides a
complete Claude Code development environment:

**Installed tools (via nixpkgs):**

- bashInteractive, coreutils, findutils, gnugrep, gnused, gawk
- git, nodejs, curl, vim, less
- cacert, openssh (sshd)
- claude-code (from nixpkgs — avoids `/usr/bin/env` shebang issues)
- nix (single-user mode for `nix develop`)

**Boot-time setup (entrypoint):**

1. Generate SSH host keys (if first start)
2. Write `/etc/resolv.conf` from `SANDBOX_DNS` env var
3. Initialize Nix store DB + register image closure (parallelized, runs in background)
4. Set up git credential helper from `SANDBOX_GIT_TOKEN` (token in file, not in URL)
5. Clone repo from `SANDBOX_REPO_URL` with proper name (`SANDBOX_REPO_NAME`)
6. Add upstream remote (`SANDBOX_UPSTREAM_URL`) if set
7. Wait for Nix store init, then exec sshd

**Security features:**

- Git credential helper: token stored in `/workspace/.config/git/token`, not embedded in
  clone URLs or git remote config. Token accessible only to the claude user.
- Internal CA trust: step-ca root certificate concatenated with public CAs for TLS to
  `creil.internal` and other internal services.
- Nix single-user mode: `build-users-group =` in nix.conf, no nixbld group needed.
- User home is `/workspace` — SSH sessions land directly in the workspace.

**Nix develop support:**

- `closureInfo` generates store registration data at build time
- Entrypoint runs `nix-store --init` + `nix-store --load-db` to populate the Nix DB
- `/nix/var` pre-chowned to claude user so nix commands work without root
- Enables `nix develop` to pull in project-specific dependencies (e.g., Rust toolchain)

## Security Notes

**Container name injection (issue 3):** The CLI prefixes all container names with `cc-` and deployd-helper validates names (alphanumeric + hyphen + underscore only).

**SSH host key verification (issue 4):** `cc-sandbox ssh` uses `StrictHostKeyChecking=no` because containers generate ephemeral host keys on boot. The proper fix is having containers request SSH host certificates from step-ca, which requires deploy-dmz egress to the CA. Deferred — tracked as a future improvement.

**Git credential isolation:** Forgejo tokens are passed via `SANDBOX_GIT_TOKEN` env var
and written to a file at `/workspace/.config/git/token` (mode 600). The git credential
helper reads from this file. Tokens are NOT embedded in git remote URLs, preventing
accidental exposure via `git remote -v` or `.git/config`.

**Resource limits:** Each sandbox container runs with configurable memory and CPU limits
(default: 4GB memory, 2 CPUs). Limits are passed through the full deployd stack as
`--memory` and `--cpus` nerdctl flags. Prevents a single sandbox from exhausting host
resources.

**Outbound internet:** Containers on deploy-dmz have unrestricted outbound access by
design (needed for `npm install`, `cargo fetch`, etc. during `nix develop`). Lateral
movement between containers is blocked by nftables rules.

## Other Changes

**Container lateral movement blocked:** `modules/deployd/default.nix` nftables rule changed from `accept` to `drop` for container-to-container traffic on deploy-dmz. Per-container rules deferred to Phase D4 (game servers).

## Create Flow (prototype, end-to-end)

Prototype flow using daemon + CLI. Phase 7 replaces this with the `init` / `up` / `down`
workflow described in that section.

1. User runs `cc-sandbox rebuild-image` (once, or when image changes)
   - CLI builds image (`nix build`), pushes to creil (`skopeo`), sends digest to daemon via socket
2. User runs `cc-sandbox create [--repo owner/repo]`
   - CLI sends `create` to daemon via Unix socket
3. Daemon generates Trails-themed hostname → `silver-blade`, container name → `cc-silver-blade`
4. Daemon reads cached image digest from state file
5. If repo specified: daemon forks on Forgejo under "cc" org, gets fork URL
6. Daemon calls deployd-api POST `/api/v1/deploy` with:
   - Image ref (digest-pinned)
   - Env vars: `SANDBOX_REPO_URL` (unauthenticated URL), `SANDBOX_REPO_NAME`, `SANDBOX_GIT_TOKEN`, `SANDBOX_DNS`, `SANDBOX_UPSTREAM_URL`
   - Resource limits: `memory` (e.g. "4g"), `cpus` (e.g. "2")
7. deployd-helper generates systemd unit with `--memory` and `--cpus` flags, starts container, retrieves IP via ctr + CNI state
8. Container entrypoint: writes resolv.conf, inits nix store (background), sets up git credential helper, clones repo, adds upstream remote, starts sshd
9. Daemon writes state, returns `{name: "silver-blade", ip: "10.97.100.5"}` to CLI
10. CLI prints: `Sandbox "silver-blade" ready at 10.97.100.5 — run: cc-sandbox ssh silver-blade`

## Addendum: deployd-helper privilege redesign (deployd-exec wrapper)

### Problem

During D0 validation, `cc-sandbox create` successfully deploys a Kata container on
erebonia but cannot retrieve the container's IP address. The root cause: containerd
runs as root, but deployd-helper runs as unprivileged `deployd-helper` user. When
deployd-helper calls `nerdctl inspect`, nerdctl 2.x defaults to rootless mode for
non-root callers and looks in a different containerd namespace, failing to find the
container. The existing ACLs on the containerd socket and `/var/lib/nerdctl` are
insufficient — the namespace mismatch is a nerdctl-level behavior, not a filesystem
permission issue.

More broadly, deployd-helper's privilege model has accumulated three ACL services
(`deployd-unit-acl`, `deployd-containerd-acl`, `deployd-vsock-acl`) and a polkit
rule to work around the fact that it needs root-level operations (writing systemd
units, running systemctl, running nerdctl inspect) while running as a non-root user.

### Solution: `deployd-exec` privileged wrapper

Replace the ACL + polkit approach with a single, auditable sudo wrapper. A small
shell script (`deployd-exec`) lives in the Nix store (read-only, immutable) and
handles all root operations. deployd-helper invokes it via `sudo` with a restrictive
sudoers rule that permits exactly one store path.

**deployd-exec subcommands:**

| Subcommand                         | What it does                                                                                                                              |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- |
| `write-unit <name> [--persistent]` | Reads unit content from stdin, validates name, writes to `/run/systemd/system/` or `/etc/systemd/system/`, runs `systemctl daemon-reload` |
| `start <name>`                     | `systemctl start <name>.service`                                                                                                          |
| `stop <name>`                      | `systemctl stop <name>.service` (ignores already-stopped)                                                                                 |
| `remove-unit <name>`               | Removes unit file from both dirs, runs `systemctl daemon-reload`                                                                          |
| `inspect <name>`                   | `nerdctl inspect <name>` → outputs `{"ip": "..."}` JSON                                                                                   |

Each subcommand validates the container name (alphanumeric + hyphen + underscore,
matching deployd-helper's existing validation) before executing.

**NixOS wiring:**

```nix
# Sudoers rule — deployd-helper can run exactly this store path, no password
security.sudo.extraRules = [{
  users = ["deployd-helper"];
  commands = [{
    command = "${deployd-exec}";
    options = ["NOPASSWD"];
  }];
}];
```

The script is a `pkgs.writeShellScript` or `pkgs.writeShellScriptBin` in the
deployd module — contained entirely in the Nix store, no mutable files.

### What gets removed

| Component                               | Status                                                    |
| --------------------------------------- | --------------------------------------------------------- |
| `deployd-unit-acl` service              | **Removed** — wrapper writes units as root                |
| `deployd-containerd-acl` service        | **Removed** — wrapper runs nerdctl as root                |
| Polkit rule for deployd-helper          | **Removed** — wrapper runs systemctl as root              |
| `/var/lib/nerdctl` tmpfiles rule + ACLs | **Removed** — wrapper accesses as root                    |
| `deployd-vsock-acl` service             | **Stays** — vsock socket ownership (unrelated to nerdctl) |

Net: 2 ACL services, 1 polkit rule, and 1 tmpfiles entry removed. 1 sudoers rule
and 1 store-path script added.

### Changes to deployd-helper (Rust)

- Remove `systemctl()` method and `nerdctl inspect` call from `executor.rs`
- Replace with single `deployd_exec()` method that invokes `sudo <deployd-exec> <subcommand> <args>`
- Remove config fields: `nerdctl_path`, `systemctl_path`
- Add config field: `deployd_exec_path` (store path to the wrapper)
- `deploy()`: generate unit content → pipe to `deployd_exec write-unit <name>` → `deployd_exec start <name>`
- `teardown()`: `deployd_exec stop <name>` → `deployd_exec remove-unit <name>`
- `inspect()`: `deployd_exec inspect <name>` → parse JSON result

### Changes to deployd module (Nix)

- Add `deployd-exec` script as `pkgs.writeShellScript` within `default.nix`
- Add `security.sudo.extraRules` entry
- Remove `deployd-unit-acl` service
- Remove `deployd-containerd-acl` service
- Remove polkit `extraConfig` block
- Remove `/var/lib/nerdctl` tmpfiles rule
- Remove `/var/lib/nerdctl` from `ReadWritePaths`
- Remove `/run/systemd/system` and `/etc/systemd/system` from `ReadWritePaths`
- Add `DEPLOYD_EXEC_PATH` environment variable pointing to sudo + wrapper
- Ensure `sudo` is accessible to deployd-helper (add to service PATH or use absolute path)

### Changes to deployd-helper service hardening

The service config gets tighter:

```nix
ReadWritePaths = [
  "/var/log/deployd"          # audit log (stays)
  (builtins.dirOf cfg.vsockHostSocket)  # vsock (stays)
  # Removed: /run/systemd/system, /etc/systemd/system, /var/lib/nerdctl
];
```

deployd-helper's only remaining privilege escalation path is the single sudoers rule,
which is scoped to one immutable binary.

## Phase 7: Repo-Centric Design — STEP 1 COMPLETE

With deployd validated, cc-sandbox can be designed as a product rather than a test
harness. Feedback from using the prototype identified four problems: the tool is
over-engineered as a system service, the image rebuild workflow is error-prone, too many
manual steps to reach a working sandbox, and Claude config/memories are lost on teardown.

These are symptoms of the prototype's container-centric model — which was appropriate for
testing deployd (where the container lifecycle was the thing being validated) but wrong
for a tool whose purpose is enabling Claude Code to work on repos. Rather than patch the
prototype, the design starts from the right abstraction: **cc-sandbox is a project/repo
manager with container features, not a container manager with repo features.**

### The design

**Prototype model:** cc-sandbox is a container lifecycle tool. The primary object is a
container. A repo is an optional parameter at creation time. Everything is ephemeral —
fork, dev shell, Claude state created fresh and destroyed on teardown.

**Product model:** cc-sandbox is a project tool. The primary object is a registered repo
profile. Containers are transient execution environments spawned from the profile. The
profile is durable — it persists the fork URL, the dev shell closure, and Claude state
across sandbox sessions.

This resolves each prototype problem naturally:

| Problem                         | Why it resolves                                                     |
| ------------------------------- | ------------------------------------------------------------------- |
| System service over-engineering | A project tool belongs in the user's environment, not the system    |
| Manual image rebuild            | Image is an implementation detail of `up`, not user-facing          |
| Too many steps                  | `init` once, then `up` does everything                              |
| Lost Claude state               | Per-project persistent state directory, mounted into each container |

### Hard dependency: eliminate daemon, move to home-manager

**The repo-centric model requires cc-sandbox to be a single user-managed CLI tool, not
a system service with a daemon/CLI split.** This is a hard dependency, not a nice-to-have
cleanup.

A repo-centric tool fundamentally operates on user-level concerns:

- It references the user's local git checkouts for flake evaluation
- It stores per-project state (fork URLs, dev shell closures, Claude memories) that
  belongs to the user, not the system
- It builds nix derivations using the user's nix store and substituter config
- It auto-detects projects from the user's current working directory

A system service (running as `cc-sandbox` user with sops-managed secrets) cannot
naturally do any of these things. It can't see the user's git checkouts, can't build
nix derivations (PATH restricted by design), and stores state in `/var/lib/` rather
than the user's home.

Furthermore, the daemon itself is no longer justified. It existed for privilege
separation: the daemon held secrets while the CLI held nix. But there is only one
principal — the user. Every daemon responsibility is trivially handled by the CLI
directly:

| Daemon responsibility  | Without daemon                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| OIDC token caching     | File-based cache in `$XDG_STATE_HOME/cc-sandbox/token.json` with expiry. Standard pattern (gcloud, aws, gh all do this). |
| Forgejo token          | CLI reads directly from sops-nix-decrypted file                                                                          |
| State serialization    | CLI takes flock on state file directly                                                                                   |
| deployd-api HTTP calls | CLI makes requests directly                                                                                              |
| Image digest tracking  | CLI writes to state file after push                                                                                      |

**What cc-sandbox becomes:** A single CLI binary. No daemon process, no Unix socket
protocol, no socket permissions, no systemd service. It reads config from
`~/.config/cc-sandbox/`, reads/writes state in `$XDG_STATE_HOME/cc-sandbox/`, reads
secrets from sops-nix home-manager managed files, and directly calls Keycloak +
deployd-api + Forgejo APIs.

**Home-manager integration:**

- cc-sandbox package installed via home-manager `home.packages`
- Secrets managed by sops-nix's home-manager integration (`sops.secrets` in the
  home-manager config), decrypted to `$XDG_RUNTIME_DIR/secrets/` or similar
  - Forgejo personal access token (for the "cc" bot user — see "Forgejo bot user" below)
  - No OIDC client secret needed (public client with PKCE — see "User auth" below)
- Config file at `~/.config/cc-sandbox/config.json` managed by home-manager
  (API URLs, registry, CA cert path, DNS servers, resource limits)
- State in `$XDG_STATE_HOME/cc-sandbox/` (projects, token cache, image digest)

**What gets removed from NixOS config:**

- `hosts/calvard/incus/guests/edith/modules/cc-sandbox.nix` — entire NixOS module
- `cc-sandbox` system user and group
- sops secret declarations in `hosts/calvard/incus/guests/edith/sops.nix`
- systemd system service
- `mutantmell` group membership for socket access
- System-wide environment variables for CLI config

**What gets added to home-manager config:**

- `home.packages = [pkgs.mmell.cc-sandbox]`
- sops-nix home-manager secret (forgejo-token only)
- `xdg.configFile."cc-sandbox/config.json"` with API URLs, registry, etc.

**What gets removed from cc-sandbox Python code:**

- Daemon main loop and socket server
- Unix socket protocol (message format, bounded reads, socket auth)
- `set-digest` command (CLI writes state directly)
- `daemon` subcommand and forking logic
- All socket client code in CLI commands
- Client credentials grant (replaced by auth code / device grant flow)

### User authentication (replaces service account)

The prototype authenticated to deployd-api as a Keycloak service account (client
credentials grant). This was appropriate when a system daemon held the credentials,
but with a user-facing CLI tool it's the wrong abstraction — deployd-api sees "something
with `deploy` permission" rather than who is actually deploying.

**Change:** cc-sandbox authenticates as the user's own Keycloak account. deployd-api
gets real user identity in the JWT claims.

**What this simplifies:**

- **Eliminates the OIDC client secret entirely.** The Keycloak client changes from
  confidential (client credentials grant, requires a secret) to public (authorization
  code + PKCE, no secret). Public clients with PKCE are the recommended OAuth 2.1
  approach for native/CLI applications.
- **One fewer sops secret.** The entire `cc-sandbox-client-secret` sops entry and its
  management goes away. Only the Forgejo token remains.
- **No more service account.** The `cc-sandbox` Keycloak client's service account (with
  its `deploy` group mapping) is removed. The user's own group memberships control access.
- **Audit trail gets real identity.** deployd-api can log "mutantmell deployed X" instead
  of "service-account-cc-sandbox deployed X."
- **Future-proofs deployd-api.** Per-user resource quotas, rate limits, deployment limits
  all become possible because deployd-api knows who's asking. Not in scope now, but the
  foundation is correct.

**OAuth flow — Authorization Code with PKCE + Device Grant fallback:**

For interactive sessions with a browser:

1. First use: `cc-sandbox init` (or first `up`) detects no cached token
2. CLI starts a temporary localhost HTTP server (random port callback)
3. Opens browser to Keycloak's authorize endpoint with PKCE challenge
4. User authenticates, Keycloak redirects to localhost with auth code
5. CLI exchanges code for access token + refresh token
6. Tokens cached in `$XDG_STATE_HOME/cc-sandbox/token.json` (mode 600)
7. Subsequent commands use cached access token; refresh when expired

For SSH sessions without a browser (the common case on edith):

1. CLI detects no display / no browser available
2. Falls back to Device Authorization Grant (RFC 8628)
3. Prints a URL and a one-time code (like `gh auth login` over SSH)
4. User opens URL on any browser (laptop, phone), enters code, authenticates
5. CLI polls Keycloak's token endpoint until authorization completes
6. Same token caching as above

**Changes by component:**

| Component              | Change                                                                                                                                           |
| ---------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| **Keycloak**           | `cc-sandbox` client: confidential → public, enable auth code + device grant, require PKCE, remove service account and its `deploy` group mapping |
| **cc-sandbox CLI**     | Replace client credentials grant with auth code/device flow + PKCE + token refresh                                                               |
| **cc-sandbox secrets** | Remove `cc-sandbox-client-secret` from sops entirely                                                                                             |
| **deployd-api**        | Minimal — already validates JWT and checks group claims. Optionally extract `sub`/`preferred_username` for audit logging                         |

**Manual steps (updated for Phase 7):**

- Reconfigure `cc-sandbox` Keycloak client (homelab realm):
  - Client authentication: OFF (public client)
  - Grant types: authorization code + device authorization
  - PKCE: required (S256)
  - Valid redirect URIs: `http://localhost:*` (for auth code callback)
  - Remove service account and its group mappings
- Ensure mutantmell's Keycloak account has the `deploy` group membership
- Remove `cc-sandbox-client-secret` from sops secrets

### Forgejo bot user

The "cc" Forgejo user and its personal access token are retained as-is. This is a
deliberate choice, not a leftover:

- The dotfiles repo is owned by the user's personal Forgejo account. Having a separate
  "cc" bot user for forks keeps the permission model clean — the bot can
  write:repository + write:package to its own namespace without needing write access to
  the user's repos.
- Forgejo's UI makes it easier to manage permissions with a separate bot user than with
  fine-grained token scopes on the primary account.
- If Forgejo adds better bot user / integration support in the future, the "cc" user
  can be migrated to that. For now, a regular user account is the most straightforward
  approach.

The Forgejo token remains the single sops-managed secret in cc-sandbox.

### Architecture (Phase 7)

```
  [edith (10.97.21.42, lab zone)]
    cc-sandbox CLI (runs as mutantmell, installed via home-manager)
      - Forgejo token from sops-nix home-manager
      - Config from ~/.config/cc-sandbox/config.json
      - State in $XDG_STATE_HOME/cc-sandbox/ (projects, token cache, image digest)
      - Auth: user's Keycloak account (auth code + PKCE / device grant)
      - Directly calls: Keycloak, deployd-api, Forgejo
      - Directly runs: nix build, skopeo push, nix copy
      |
      | HTTPS (user Bearer token, deploy group)
      v
    [roer.internal] → deployd-api → deployd-helper → containerd/Kata
      |
      | deploy response includes container IP
      v
    [sandbox container on deploy-dmz (10.97.100.x, gateway 10.97.100.1)]
      - CNI macvlan on deploy-dmz VLAN, own IP
      - Clones SANDBOX_REPO_URL on startup (git credential helper for auth)
      - User SSH keys authorized in image
      - Claude Code (nixpkgs) + nix develop (deps pre-pushed via nix copy)
      - Per-project Claude state volume mounted from host
      - Resource-limited (memory + CPU via nerdctl flags)
```

### Workflow

```
# One-time: register a project
cc-sandbox init                     # auto-detect repo from cwd
cc-sandbox init owner/repo          # or by name (clones to a managed dir)

  -> forks on Forgejo under "cc" org (one-time)
  -> records local checkout path
  -> builds dev shell closure if flake.nix present
  -> creates profile: ~/.local/state/cc-sandbox/projects/<owner>-<repo>/

# Spin up a sandbox
cc-sandbox up                       # auto-detect project from cwd
cc-sandbox up owner/repo            # or explicit

  -> ensures container image is current (auto-rebuild + push if stale)
  -> deploys container with fork URL, env vars, Claude state volume
  -> in parallel: builds dev shell locally (if stale / flake.lock changed)
  -> waits for SSH readiness (TCP poll with backoff)
  -> nix copy dev shell closure to container
  -> returns: sandbox ready, prints ssh command

# Work
cc-sandbox ssh                      # auto-detect, execs nix develop as shell
cc-sandbox ssh --no-develop         # plain shell without dev environment

# Done
cc-sandbox down                     # tears down container, profile persists

# Later — fork exists, dev shell cached, Claude memories preserved
cc-sandbox up                       # near-instant if nothing changed
```

### Project profile

Each registered project gets a profile directory:

```
~/.local/state/cc-sandbox/
  claude/                             # shared Claude state, mounted into all containers
  projects/<owner>-<repo>/
    profile.json                      # fork URL, upstream URL, local checkout path,
                                      #   dev shell store path, container name (when running),
                                      #   container IP (when running)
```

`profile.json` fields:

- `owner`, `repo` — canonical project identity
- `fork_url` — Forgejo fork URL (set at init, reused on every up)
- `upstream_url` — original repo URL (set at init)
- `checkout_path` — local git checkout used for flake eval (set at init)
- `dev_shell_path` — last-built dev shell store path (updated on up)
- `dev_shell_flake_lock_hash` — hash of flake.lock when dev shell was last built
  (used to detect staleness)
- `container_name` — active container name, null when down
- `container_ip` — active container IP, null when down

### Auto image rebuild

The container image is a pure Nix derivation — its output path is fully determined by
its inputs. The `up` command handles image currency automatically:

1. `nix build` the image (fast if inputs unchanged — nix cache hit)
2. Compute digest from build output
3. Compare against last-pushed digest in state
4. If different: push with `skopeo`, update state
5. Proceed with deploy

The user never thinks about images. A separate `cc-sandbox rebuild-image` stays as an
explicit override for debugging but is rarely needed.

### Local dev shell build + nix copy

Rather than running `nix develop` inside the resource-constrained container (4GB RAM,
2 CPUs), build the dev shell on edith and push the closure to the container over SSH.

**On `up`:**

1. Check if dev shell is stale: compare current `flake.lock` hash against
   `dev_shell_flake_lock_hash` in profile
2. If stale (or first run): `nix build <checkout>#devShells.x86_64-linux.default`
   - Runs in parallel with container deploy — doesn't add latency if deploy is slower
3. After SSH readiness + nix store DB init: `nix copy --to ssh://claude@<ip> <path>`
   - Only transfers store paths not already present in the container
4. In the container, `nix develop` is instant — everything is already in the store

**Why this works well with the repo-centric model:**

The `init` step records the local checkout path. The `up` step uses that checkout to
evaluate the flake. There's no need to clone separately or guess where the repo is —
the profile knows.

**Important subtlety: the local machine must be able to evaluate the repo's flake.**
This means edith needs:

- The local checkout recorded in the profile (the path from `init`)
- Network access to fetch flake inputs (resolving `flake.lock` entries)
- The same system architecture as the container (`x86_64-linux` — true for edith and
  the Kata VMs on erebonia, but this should be asserted explicitly, since a future
  scenario where cc-sandbox runs on a non-x86_64 machine would silently produce
  unusable store paths)

If the repo has no `flake.nix`, the dev shell step is skipped entirely.

**Entering the dev shell on SSH:**

After `nix copy` populates the store, `cc-sandbox ssh` needs to activate the dev shell.
Options (to be decided during implementation):

- Let `cc-sandbox ssh` exec `nix develop` as the SSH command — cleanest, user can
  opt out with `cc-sandbox ssh --no-develop`
- `nix print-dev-env` on edith, ship the output, source it in `.bash_profile` — instant
  activation, but fragile across nix versions
- Write a `.bash_profile` that runs `nix develop` (instant since deps are cached) —
  simplest, but adds latency to every shell start

### Claude state persistence

A shared `claude/` directory at `~/.local/state/cc-sandbox/claude/` is mounted into
every container at `/workspace/.claude/`. Claude state (auth tokens, global memories,
settings) is user-scoped, not project-scoped — it makes sense to share it across all
sandboxes, just as `~/.claude/` is shared across all local projects.

Claude Code already scopes project-level memories by workspace directory path internally,
so different repos get different project memories even within the same `~/.claude/`
directory. The shared volume mirrors how Claude Code works on a normal workstation.

**No deployd-api or deployd-helper changes required.** The full volume pipeline already
exists end-to-end:

- deployd-api (`helper.rs`) accepts `volumes: Vec<VolumeMount>` and passes through
- deployd-helper validates volume mounts (absolute paths, no `..`, blocks `/etc /boot
/proc /sys /dev /nix`) then generates `--volume=host:container` nerdctl flags
- cc-sandbox adds a `volumes` entry to the deploy payload

**Changes (cc-sandbox only):**

1. Shared directory at `~/.local/state/cc-sandbox/claude/`, created on first `up`
2. Directory ownership set to match container's `claude` user UID/GID (Kata uses a
   real VM with no user namespace remapping — host UID must match image UID)
3. Every deploy payload includes volume:
   ```python
   volumes=[{"host": "~/.local/state/cc-sandbox/claude",
             "container": "/workspace/.claude"}]
   ```
4. First-time setup: pre-populate with auth token so the first sandbox doesn't need
   manual authorization

**Security considerations:**

1. **Host path exposure.** The volume mount exposes a state subdirectory into a Kata
   VM. The path passes deployd-helper's validation (not under any blocked prefix). The
   Kata VM boundary means the container can only see this specific mount, not the host
   filesystem — stronger than a normal container bind mount.

2. **Claude auth token on disk.** The `.claude/` directory contains an API key or OAuth
   token. With persistence, this lives on erebonia's disk under the user's state
   directory. This is the same trust model as sops secrets on that host. The directory
   should be mode 700.

3. **Concurrent sandboxes.** If two sandboxes run simultaneously with the same shared
   mount, both write to the same `claude/` directory. SQLite (which Claude Code may use
   internally) handles concurrent writes from different hosts poorly. For single-user,
   one-at-a-time usage a simple bind mount is sufficient. The `up` command can warn if
   another sandbox is already running.

4. **Volume mount permissions.** The container's `claude` user has a fixed UID/GID set
   in the image. The shared directory must be owned by that same UID. The first `up`
   handles this. Since Kata uses a VM (no user namespace remapping), the UID mapping
   is direct.

5. **Container-path validation gap (pre-existing).** deployd-helper validates host paths
   but does not restrict container mount targets. A compromised cc-sandbox process could
   mount to arbitrary container paths. This is not new — any deployd client can already
   specify arbitrary container paths. The mount target (`/workspace/.claude`) is benign.
   A future hardening could add a container-path allowlist to deployd-helper.

### Bare sandbox (no project)

The repo-centric model makes project-less sandboxes a secondary use case. For ad-hoc
environments without a repo:

```
cc-sandbox up --bare                # no repo, no dev shell, no project profile
```

This skips fork/clone/dev shell steps but still mounts the shared Claude state directory.
Equivalent to the current `cc-sandbox create` without `--repo`.

### Implementation order

1. **Eliminate daemon + home-manager migration + user auth** — COMPLETE. Daemon removed,
   CLI calls APIs directly. OAuth auth code + PKCE with device grant fallback replaces
   client credentials grant. Config from `~/.config/cc-sandbox/config.json`, state in
   `$XDG_STATE_HOME/cc-sandbox/`. Home-manager module at `home/modules/cc-sandbox.nix`,
   edith host config at `home/hosts/edith.nix`. NixOS module + system service removed.
   **Manual steps remaining:** Keycloak client reconfiguration, sops secret creation for
   HM (see below).
2. **Project profiles + init/up/down** — new CLI commands, profile directory structure,
   auto-detect from cwd. Fork moves from `up` to `init`.
3. **Auto image rebuild** — integrate into `up`. Remove manual rebuild as primary path.
4. **Local dev shell build + nix copy** — build locally, push to container, SSH readiness
   polling.
5. **Claude state persistence** — shared `claude/` volume mount.

Each step is independently deployable and testable. Steps 2-5 depend on step 1.

## Verification

1. `nix build .#cc-sandbox` — package builds
2. `nix build .#checks.x86_64-linux.deployd` — deployd test still passes
3. `cc-sandbox init` from within a repo checkout creates profile
4. `cc-sandbox up` deploys container, waits for SSH, pushes dev shell
5. `cc-sandbox ssh` drops into dev shell inside container
6. `cc-sandbox down` + `cc-sandbox up` — Claude memories persist across sessions
7. `cc-sandbox up` with no changes — near-instant (image cached, dev shell cached)
8. `cc-sandbox list` shows registered projects and their status

## Step 1 Manual Steps (post-deploy)

1. **Keycloak** — reconfigure `cc-sandbox` client in homelab realm:
   - Client authentication: OFF (public client)
   - Grant types: authorization code + device authorization
   - PKCE: required (S256)
   - Valid redirect URIs: `http://localhost:*`
   - Remove service account and its group mappings
   - Ensure mutantmell's account has `deploy` group membership

2. **sops secrets for home-manager** — create `home/hosts/edith/secrets.yaml`:
   - Get mutantmell's age public key: `ssh-to-age -i ~/.ssh/id_ed25519.pub`
   - Add the age key to `.sops.yaml` with an anchor (e.g. `&user_mutantmell_edith`)
   - Add a creation rule: `path_regex: home/hosts/edith/secrets\.yaml$`
   - Create with: `sops home/hosts/edith/secrets.yaml`
   - Add key: `cc-sandbox-forgejo-token` (same value as current NixOS secret)

3. **Cleanup** — after HM deploy is verified working:
   - Remove `cc-sandbox-client-secret` from edith's NixOS sops secrets file
   - Remove `cc-sandbox-forgejo-token` from edith's NixOS sops secrets file
   - Stop and disable the old `cc-sandbox` systemd service on edith
