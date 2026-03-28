# cc-sandbox: Claude Code Sandbox Orchestrator

## Context

With deployd validated end-to-end (D0 complete), the next step is automating sandbox lifecycle. Currently, creating a Claude Code sandbox requires manually running a 200-line shell script that builds an image, pushes it, authenticates with Keycloak, deploys via the API, discovers the container IP, and SSHs in. cc-sandbox automates this into `cc-sandbox create` / `cc-sandbox ssh <name>` / `cc-sandbox teardown <name>`.

## Architecture

```
  [edith (10.97.21.42, lab zone)]
    cc-sandbox CLI (runs as mutantmell)
      - rebuild-image: nix build + skopeo push (privileged)
      - create/teardown/list/ssh: talks to daemon via Unix socket

    cc-sandbox daemon (systemd service, cc-sandbox user)
      - Unix socket: /run/cc-sandbox/cc-sandbox.sock
      - Holds: Keycloak creds, Forgejo token (sops)
      - State: /var/lib/cc-sandbox/state.json
      - NO nix, skopeo, or SSH access
      |
      | HTTPS (password grant → Bearer token)
      v
    [roer.internal] → deployd-api → deployd-helper → containerd/Kata
      |
      | deploy response includes container IP
      v
    [sandbox container on br-deploy (10.100.0.x)]
      - Direct route from edith exists
      - Clones SANDBOX_REPO_URL on startup (env var from deployd)
      - User SSH keys authorized in image
```

## Language: Python

cc-sandbox is a thin orchestration layer — the daemon makes HTTP calls to Keycloak and deployd-api. The CLI additionally shells out to `nix build` and `skopeo` for image management. Python with `requests` and standard library is sufficient and much faster to develop than Rust.

Packaging: `stdenv.mkDerivation` with `makeWrapper` around `python3.withPackages`, following the `openwrt-builder` pattern.

## Privilege Separation

The daemon and CLI have different privilege levels:

| Capability          | Daemon (cc-sandbox user) | CLI (mutantmell)             |
| ------------------- | ------------------------ | ---------------------------- |
| OIDC client secret  | Yes (sops secret)        | No                           |
| Forgejo token       | Yes (sops secrets)       | Yes (reads token file)       |
| deployd-api access  | Yes (via Keycloak token) | No (via daemon socket)       |
| nix build           | No                       | Yes                          |
| skopeo push/inspect | No                       | Yes                          |
| SSH to containers   | No                       | No (user SSHs directly)      |
| State file          | Read/write               | No (sends digest via socket) |

The daemon's systemd service restricts PATH to exclude nix/skopeo. Image building runs as the calling user via `cc-sandbox rebuild-image`.

## Prerequisite: deployd-helper returns container IP on inspect — COMPLETE

deployd-helper's Inspect command retrieves the container IP. The implementation
has gone through several iterations:

1. ~~`nerdctl inspect`~~ — failed due to nerdctl v2 rootful/rootless namespace confusion
2. **Current:** `deployd-exec inspect` uses `ctr` (containerd's native gRPC CLI)
   to find the container by nerdctl name label, then scans CNI host-local IPAM
   state files for the IP. Works but involves fragile shell parsing (see
   "Containerd gRPC Consolidation" in `deployd-integration.md` for planned fix).

Returns IP in the `HelperResponse.data` field. deployd-api forwards `data` to
HTTP callers. cc-sandbox daemon reads IP from the deploy response.

Planned: Phase D1c will replace the entire inspect path by having deployd-helper
invoke CNI directly during container creation. The IP will be a return value from
CNI ADD, eliminating the need for a separate inspect step. See
`deployd-integration.md` "Architecture Change: Replace nerdctl with Containerd
gRPC" for details.

**Files modified:**

- `modules/deployd/default.nix` — `deployd-exec inspect` subcommand (ctr + CNI state scan)
- `packages/deployd-helper/src/executor.rs` — calls deployd-exec inspect, parses result

## Phase 1-3: Python Package — COMPLETE

Single Python file (`cc_sandbox.py`) with daemon + CLI:

**Daemon commands (via Unix socket):**

- `create [--repo <url>]` — generate hostname, fork repo on Forgejo, deploy container with `SANDBOX_REPO_URL` env var
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
- Container env var for repo cloning (no SSH from daemon into containers)

## Phase 4: Forgejo Integration — COMPLETE (in Phase 1-3)

Repo forking via Forgejo API is integrated into the daemon's `create` handler. The fork URL is passed as `SANDBOX_REPO_URL` env var to the container, and the container entrypoint handles cloning.

## Phase 5: NixOS Wiring on edith — COMPLETE

**New files:**

- `hosts/calvard/incus/guests/edith/modules/cc-sandbox.nix` — NixOS module with options:
  - `services.cc-sandbox.enable` + apiUrl, authUrl, registry, forgejoUrl, caCert, flakePath, flakeAttr
  - Systemd service: runs as `cc-sandbox` system user, hardened (ProtectSystem, NoNewPrivileges, restricted address families/syscalls)
  - Daemon PATH restricted to just the cc-sandbox package (no nix/skopeo/ssh)
  - `mutantmell` added to `cc-sandbox` group (socket access)
  - Sops secrets: client-secret, forgejo-token (token readable by group for CLI image push)
  - Impermanence: persist `/var/lib/cc-sandbox`
  - Env vars for daemon: secret file paths, API URLs, registry, CA cert
  - Env vars for CLI: socket path, registry, flake path/attr, forgejo token file (system-wide via environment.variables)

**Modified files:**

- `hosts/calvard/incus/guests/edith/default.nix` — import module, enable with production URLs
- `hosts/calvard/incus/guests/edith/sops.nix` — declare cc-sandbox secrets

**Manual steps (before deploy):**

- Create "cc" user on Forgejo (creil), generate personal access token with write:repository + write:package
- Create `cc-sandbox` confidential client in Keycloak (homelab realm):
  - Client authentication: ON (confidential)
  - Grant type: client credentials only
  - Map the `deploy` group to the client's service account (so tokens carry the group claim)
- Create `hosts/calvard/incus/guests/edith/secrets/secrets.yaml` with sops:
  - `cc-sandbox-client-secret`, `cc-sandbox-forgejo-token`

## Phase 6: Update deployd integration doc — NOT STARTED

- `llm-notes/wip/deployd-integration.md` — mark D0 complete, document cc-sandbox

## Security Notes

**Container name injection (issue 3):** The daemon prefixes all container names with `cc-` and deployd-helper validates names (alphanumeric + hyphen + underscore only). For multi-user scenarios, add per-user namespacing or authentication on the Unix socket.

**SSH host key verification (issue 4):** `cc-sandbox ssh` uses `StrictHostKeyChecking=no` because containers generate ephemeral host keys on boot. The proper fix is having containers request SSH host certificates from step-ca, which requires br-deploy egress to the CA. Deferred — tracked as a future improvement.

## Other Changes

**Container lateral movement blocked:** `modules/deployd/default.nix` nftables rule changed from `accept` to `drop` for container-to-container traffic on br-deploy. Per-container rules deferred to Phase D4 (game servers).

## Create Flow (end-to-end)

1. User runs `cc-sandbox rebuild-image` (once, or when image changes)
   - CLI builds image (`nix build`), pushes to creil (`skopeo`), sends digest to daemon via socket
2. User runs `cc-sandbox create [--repo owner/repo]`
   - CLI sends `create` to daemon via Unix socket
3. Daemon generates Trails-themed hostname → `silver-blade`, container name → `cc-silver-blade`
4. Daemon reads cached image digest from state file
5. If repo specified: daemon forks on Forgejo under "cc" user, gets fork URL
6. Daemon calls deployd-api POST `/api/v1/deploy` with image ref and `SANDBOX_REPO_URL` env var
7. deployd-helper starts container, retrieves IP via ctr + CNI state, returns IP in response
8. Container entrypoint clones `SANDBOX_REPO_URL` if set
9. Daemon writes state, returns `{name: "silver-blade", ip: "10.100.0.5"}` to CLI
10. CLI prints: `Sandbox "silver-blade" ready at 10.100.0.5 — run: cc-sandbox ssh silver-blade`

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

## Verification

1. `nix build .#cc-sandbox` — package builds
2. `nix build .#checks.x86_64-linux.deployd` — deployd test still passes
3. Deploy edith config, run `cc-sandbox rebuild-image`, then `cc-sandbox create`
4. `cc-sandbox ssh <name>` drops into container shell
5. `cc-sandbox create --repo owner/repo` forks and clones via env var
6. `cc-sandbox list` shows active sandboxes
7. `cc-sandbox teardown <name>` cleans up container and state
