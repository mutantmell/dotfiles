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
    [roer.internal] → deployd-api → deployd-helper → nerdctl + Kata
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

| Capability | Daemon (cc-sandbox user) | CLI (mutantmell) |
|---|---|---|
| OIDC client secret | Yes (sops secret) | No |
| Forgejo token | Yes (sops secrets) | Yes (reads token file) |
| deployd-api access | Yes (via Keycloak token) | No (via daemon socket) |
| nix build | No | Yes |
| skopeo push/inspect | No | Yes |
| SSH to containers | No | No (user SSHs directly) |
| State file | Read/write | No (sends digest via socket) |

The daemon's systemd service restricts PATH to exclude nix/skopeo. Image building runs as the calling user via `cc-sandbox rebuild-image`.

## Prerequisite: deployd-helper returns container IP on deploy — COMPLETE

deployd-helper runs `nerdctl inspect` after `systemctl start` to get the container IP. Returns it in the existing `HelperResponse.data` field. deployd-api already forwards `data` to HTTP callers. Backwards-compatible.

**Files modified:**
- `packages/deployd-helper/src/executor.rs` — `nerdctl_inspect_ip()` method, populated in deploy response

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
7. deployd-helper starts container, runs `nerdctl inspect`, returns IP in response
8. Container entrypoint clones `SANDBOX_REPO_URL` if set
9. Daemon writes state, returns `{name: "silver-blade", ip: "10.100.0.5"}` to CLI
10. CLI prints: `Sandbox "silver-blade" ready at 10.100.0.5 — run: cc-sandbox ssh silver-blade`

## Verification

1. `nix build .#cc-sandbox` — package builds
2. `nix build .#checks.x86_64-linux.deployd` — deployd test still passes
3. Deploy edith config, run `cc-sandbox rebuild-image`, then `cc-sandbox create`
4. `cc-sandbox ssh <name>` drops into container shell
5. `cc-sandbox create --repo owner/repo` forks and clones via env var
6. `cc-sandbox list` shows active sandboxes
7. `cc-sandbox teardown <name>` cleans up container and state
